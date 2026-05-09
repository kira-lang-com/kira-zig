import struct, sys

def read_string(data, pos):
    length = struct.unpack_from('<I', data, pos)[0]
    pos += 4
    s = data[pos:pos+length].decode('utf-8', errors='replace')
    pos += length
    return s, pos

def read_typeref(data, pos):
    kinds = ['void','integer','float','string','boolean','construct_any','array','raw_ptr','ffi_struct','enum_instance']
    kind_idx = data[pos]; pos += 1
    kind = kinds[kind_idx] if kind_idx < len(kinds) else 'unk(%d)' % kind_idx
    name, pos = read_string(data, pos)
    constraint, pos = read_string(data, pos)
    return ('%s(%s)' % (kind, name)) if name else kind, pos

path = sys.argv[1]
filter_terms = sys.argv[2:] if len(sys.argv) > 2 else []
data = open(path, 'rb').read()
pos = 0
magic = data[:4]; pos = 4
print('magic:', magic)
module_name, pos = read_string(data, pos)
print('module:', module_name)
bytecode, pos = read_string(data, pos)
print('bytecode:', bytecode)
native, pos = read_string(data, pos)
print('native:', native)
entry_id = struct.unpack_from('<I', data, pos)[0]; pos += 4
entry_exec = data[pos]; pos += 1
fn_count = struct.unpack_from('<I', data, pos)[0]; pos += 4
print('entry_fn=%d entry_exec=%d fn_count=%d' % (entry_id, entry_exec, fn_count))
exec_names = ['runtime','native','inherited']
for i in range(fn_count):
    fn_id = struct.unpack_from('<I', data, pos)[0]; pos += 4
    exec_kind = data[pos]; pos += 1
    fn_name, pos = read_string(data, pos)
    param_count = struct.unpack_from('<I', data, pos)[0]; pos += 4
    params = []
    for j in range(param_count):
        t, pos = read_typeref(data, pos)
        params.append(t)
    ret, pos = read_typeref(data, pos)
    exported, pos = read_string(data, pos)
    ek = exec_names[exec_kind] if exec_kind < len(exec_names) else str(exec_kind)
    if not filter_terms or any(x in fn_name for x in filter_terms):
        print('  [%s] %d: %s(%s) -> %s  export=%s' % (ek, fn_id, fn_name, ', '.join(params), ret, exported))
