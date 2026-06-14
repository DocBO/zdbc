import numpy as np
import ctypes
from pyzdbc import _core
from pyzdbc._errors import ZDBCError

STR8_LEN = _core.STR8_LEN
COL_I64 = _core.COL_I64
COL_F64 = _core.COL_F64
COL_STR8 = _core.COL_STR8


def _read_str8_column(data_ptr, count):
    buf_type = ctypes.c_char * (count * STR8_LEN)
    buf = buf_type.from_address(data_ptr.value or 0)
    raw = bytes(buf)
    arr = np.frombuffer(raw, dtype=f"S{STR8_LEN}")
    return arr


def _parse_batch_result(data, size):
    buf = (ctypes.c_char * size).from_address(data.value or 0)
    hdr = _core.BatchTableHeader.from_buffer(buf)

    metas = (_core.BatchColumnMeta * hdr.num_columns).from_buffer(
        buf, _core.BATCH_HEADER_SIZE
    )

    result = {}
    for i in range(hdr.num_columns):
        meta = metas[i]
        name = meta.name.rstrip(b"\x00").decode()
        offs = meta.data_offset
        ln = meta.byte_len
        col_type = meta.col_type

        if col_type == COL_I64:
            arr = np.frombuffer(buf, dtype=np.int64, count=meta.count, offset=offs)
        elif col_type == COL_F64:
            arr = np.frombuffer(buf, dtype=np.float64, count=meta.count, offset=offs)
        elif col_type == COL_STR8:
            arr = np.frombuffer(buf, dtype=f"S{STR8_LEN}", count=meta.count, offset=offs)
        else:
            continue
        result[name] = arr.copy()

    return result


class DB:
    def __init__(self, path):
        self._path = path
        self._ptr = _core.init(path)

    def __del__(self):
        if hasattr(self, "_ptr") and self._ptr:
            _core.deinit(self._ptr)

    def close(self):
        if self._ptr:
            _core.deinit(self._ptr)
            self._ptr = None

    def create_table(self, name, schema):
        columns = []
        for col_name, col_type in schema.items():
            ct = COL_I64
            if col_type == "f64":
                ct = COL_F64
            elif col_type == "str":
                ct = COL_STR8
            columns.append((col_name, ct))
        _core.create_table(self._ptr, name, columns)

    def drop_table(self, name):
        _core.drop_table(self._ptr, name)

    def list_tables(self):
        return _core.list_tables(self._ptr)

    def table_info(self, name):
        n_cols = _core.column_count(self._ptr, name)
        n_rows = _core.row_count(self._ptr, name)
        columns = []
        for i in range(n_cols):
            cname, ctype = _core.column_info(self._ptr, name, i)
            type_name = {COL_I64: "i64", COL_F64: "f64", COL_STR8: "str"}[ctype]
            columns.append({"name": cname, "type": type_name})
        return {
            "name": name,
            "columns": columns,
            "rows": n_rows,
        }

    def read_columns(self, name, col_names=None):
        if col_names is not None:
            result = {}
            for cname in col_names:
                data_ptr, count, col_type = _core.read_column(
                    self._ptr, name, cname
                )
                if col_type == COL_I64:
                    arr = np.ctypeslib.as_array(
                        ctypes.cast(data_ptr, ctypes.POINTER(ctypes.c_int64)),
                        shape=(count,),
                    )
                    result[cname] = arr.copy()
                elif col_type == COL_F64:
                    arr = np.ctypeslib.as_array(
                        ctypes.cast(data_ptr, ctypes.POINTER(ctypes.c_double)),
                        shape=(count,),
                    )
                    result[cname] = arr.copy()
                elif col_type == COL_STR8:
                    arr = _read_str8_column(data_ptr, count)
                    result[cname] = arr.copy()
                _core.free_column(self._ptr, data_ptr, count, col_type)
            return result

        data, size = _core.read_table(self._ptr, name)
        try:
            return _parse_batch_result(data, size)
        finally:
            _core.free_table(self._ptr, data, size)

    def read_column(self, name, col_name):
        data_ptr, count, col_type = _core.read_column(self._ptr, name, col_name)
        try:
            if col_type == COL_I64:
                arr = np.ctypeslib.as_array(
                    ctypes.cast(data_ptr, ctypes.POINTER(ctypes.c_int64)),
                    shape=(count,),
                )
                return arr.copy()
            elif col_type == COL_F64:
                arr = np.ctypeslib.as_array(
                    ctypes.cast(data_ptr, ctypes.POINTER(ctypes.c_double)),
                    shape=(count,),
                )
                return arr.copy()
            elif col_type == COL_STR8:
                arr = _read_str8_column(data_ptr, count)
                return arr.copy()
        finally:
            _core.free_column(self._ptr, data_ptr, count, col_type)

    def load_table(self, name):
        columns = self.read_columns(name)
        data = {}
        for cname, arr in columns.items():
            data[cname] = arr
        import pandas as pd
        return pd.DataFrame(data)

    def write_table(self, name, df):
        col_names = []
        col_types = []
        col_ptrs = []
        arrays = []

        for col_name in df.columns:
            dtype = df[col_name].dtype
            if dtype == np.int64 or dtype == np.int32:
                ct = COL_I64
                arr = df[col_name].to_numpy(dtype=np.int64)
            elif dtype == np.float64 or dtype == np.float32:
                ct = COL_F64
                arr = df[col_name].to_numpy(dtype=np.float64)
            else:
                ct = COL_STR8
                raw = df[col_name].to_numpy(dtype=str)
                arr = np.char.ljust(raw.astype(f"S{STR8_LEN}"), STR8_LEN)

            arr_contig = np.ascontiguousarray(arr)
            arrays.append(arr_contig)
            col_names.append(col_name)
            col_types.append(ct)
            col_ptrs.append(arr_contig.ctypes.data_as(ctypes.c_void_p))

        _core.write_table(self._ptr, name, col_names, col_types, col_ptrs, len(df))

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()
