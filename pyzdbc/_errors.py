class ZDBCError(Exception):
    pass

class TableNotFoundError(ZDBCError):
    pass

class TableNotLoadedError(ZDBCError):
    pass

class SchemaError(ZDBCError):
    pass

class CorruptionError(ZDBCError):
    pass

class IOError(ZDBCError):
    pass

class MemoryError(ZDBCError):
    pass


_ERROR_MAP = {
    -1: TableNotFoundError,
    -2: TableNotLoadedError,
    -3: SchemaError,
    -4: CorruptionError,
    -5: IOError,
    -6: MemoryError,
    -7: SchemaError,
    -99: ZDBCError,
}


def check(code):
    if code < 0:
        exc_cls = _ERROR_MAP.get(code, ZDBCError)
        raise exc_cls(f"C ABI returned error code {code}")
    return code
