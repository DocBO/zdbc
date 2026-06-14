import ctypes
import os
from pyzdbc._errors import check

_HERE = os.path.dirname(os.path.abspath(__file__))
_LIB_PATH = os.environ.get(
    "ZDBC_LIB", os.path.join(_HERE, "..", "zig-out", "lib", "libzdbc.so")
)
_lib = ctypes.CDLL(_LIB_PATH)

_lib.zdbc_init.argtypes = [ctypes.c_char_p]
_lib.zdbc_init.restype = ctypes.c_void_p

_lib.zdbc_deinit.argtypes = [ctypes.c_void_p]
_lib.zdbc_deinit.restype = None

_lib.zdbc_create_table.argtypes = [
    ctypes.c_void_p, ctypes.c_char_p,
    ctypes.POINTER(ctypes.c_char_p), ctypes.POINTER(ctypes.c_uint8),
    ctypes.c_int,
]
_lib.zdbc_create_table.restype = ctypes.c_int

_lib.zdbc_drop_table.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
_lib.zdbc_drop_table.restype = ctypes.c_int

_lib.zdbc_list_tables.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint64]
_lib.zdbc_list_tables.restype = ctypes.c_int

_lib.zdbc_table_row_count.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
_lib.zdbc_table_row_count.restype = ctypes.c_int64

_lib.zdbc_table_column_count.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
_lib.zdbc_table_column_count.restype = ctypes.c_int

_lib.zdbc_table_column_info.argtypes = [
    ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int,
    ctypes.c_char_p, ctypes.c_uint64, ctypes.POINTER(ctypes.c_uint8),
]
_lib.zdbc_table_column_info.restype = ctypes.c_int

_lib.zdbc_read_column.argtypes = [
    ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p,
    ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_int64),
    ctypes.POINTER(ctypes.c_uint8),
]
_lib.zdbc_read_column.restype = ctypes.c_int

_lib.zdbc_free_sized_column.argtypes = [
    ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int64, ctypes.c_uint8,
]
_lib.zdbc_free_sized_column.restype = None

_lib.zdbc_write_table.argtypes = [
    ctypes.c_void_p, ctypes.c_char_p,
    ctypes.POINTER(ctypes.c_char_p), ctypes.POINTER(ctypes.c_uint8),
    ctypes.c_int,
    ctypes.POINTER(ctypes.c_void_p), ctypes.c_int64,
]
_lib.zdbc_write_table.restype = ctypes.c_int

_lib.zdbc_read_table.argtypes = [
    ctypes.c_void_p, ctypes.c_char_p,
    ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_int64),
]
_lib.zdbc_read_table.restype = ctypes.c_int

_lib.zdbc_free_table.argtypes = [
    ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int64,
]
_lib.zdbc_free_table.restype = None

COL_I64 = 0
COL_F64 = 1
COL_STR8 = 2
STR8_LEN = 8
BATCH_COL_NAME_LEN = 32
BATCH_COL_META_SIZE = 64

BATCH_HEADER_SIZE = 16


class BatchColumnMeta(ctypes.Structure):
    _fields_ = [
        ("name", ctypes.c_char * 32),
        ("col_type", ctypes.c_uint8),
        ("_pad1", ctypes.c_uint8 * 7),
        ("count", ctypes.c_int64),
        ("byte_len", ctypes.c_int64),
        ("data_offset", ctypes.c_int64),
    ]


class BatchTableHeader(ctypes.Structure):
    _fields_ = [
        ("num_rows", ctypes.c_int64),
        ("num_columns", ctypes.c_int32),
        ("_pad2", ctypes.c_uint8 * 4),
    ]


def init(path):
    ptr = _lib.zdbc_init(path.encode())
    if not ptr:
        raise MemoryError("Failed to initialize database")
    return ptr


def deinit(db_ptr):
    _lib.zdbc_deinit(db_ptr)


def create_table(db_ptr, name, columns):
    n = len(columns)
    col_names = (ctypes.c_char_p * n)()
    col_types = (ctypes.c_uint8 * n)()
    _encoded = []
    for i, (cname, ctype) in enumerate(columns):
        b = cname.encode()
        _encoded.append(b)
        col_names[i] = b
        col_types[i] = ctype
    check(_lib.zdbc_create_table(db_ptr, name.encode(), col_names, col_types, n))


def drop_table(db_ptr, name):
    check(_lib.zdbc_drop_table(db_ptr, name.encode()))


def list_tables(db_ptr):
    buf = ctypes.create_string_buffer(4096)
    _lib.zdbc_list_tables(db_ptr, buf, 4096)
    raw = buf.value
    if raw:
        return raw.decode().split("\n")
    return []


def row_count(db_ptr, name):
    return _lib.zdbc_table_row_count(db_ptr, name.encode())


def column_count(db_ptr, name):
    return check(_lib.zdbc_table_column_count(db_ptr, name.encode()))


def column_info(db_ptr, name, index):
    out_name = ctypes.create_string_buffer(256)
    out_type = ctypes.c_uint8()
    check(_lib.zdbc_table_column_info(
        db_ptr, name.encode(), index, out_name, 256, ctypes.byref(out_type),
    ))
    return out_name.value.decode(), out_type.value


def read_column(db_ptr, table_name, col_name):
    out_data = ctypes.c_void_p()
    out_count = ctypes.c_int64()
    out_type = ctypes.c_uint8()
    tb = table_name.encode()
    cb = col_name.encode()
    check(_lib.zdbc_read_column(
        db_ptr, tb, cb,
        ctypes.byref(out_data), ctypes.byref(out_count), ctypes.byref(out_type),
    ))
    return out_data, out_count.value, out_type.value


def free_column(db_ptr, data, count, col_type):
    if data:
        _lib.zdbc_free_sized_column(db_ptr, data, count, col_type)


def write_table(db_ptr, name, col_names, col_types, col_data_ptrs, num_rows):
    n = len(col_names)
    c_names = (ctypes.c_char_p * n)()
    c_types = (ctypes.c_uint8 * n)()
    c_data = (ctypes.c_void_p * n)()
    _encoded = []
    for i in range(n):
        b = col_names[i].encode()
        _encoded.append(b)
        c_names[i] = b
        c_types[i] = col_types[i]
        c_data[i] = col_data_ptrs[i]
    check(_lib.zdbc_write_table(
        db_ptr, name.encode(), c_names, c_types, n, c_data, num_rows,
    ))


def read_table(db_ptr, name):
    out_data = ctypes.c_void_p()
    out_size = ctypes.c_int64()
    check(_lib.zdbc_read_table(
        db_ptr, name.encode(),
        ctypes.byref(out_data), ctypes.byref(out_size),
    ))
    return out_data, out_size.value


def free_table(db_ptr, data, size):
    _lib.zdbc_free_table(db_ptr, data, size)
