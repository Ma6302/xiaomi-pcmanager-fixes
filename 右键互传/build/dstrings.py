import re, sys, os, json
def strings(path, minlen=5, unicode_ok=True):
    data = open(path,'rb').read()
    out = []
    # ascii
    for m in re.finditer(rb'[\x20-\x7e]{%d,}' % minlen, data):
        out.append(('A', m.start(), m.group().decode('latin1')))
    if unicode_ok:
        for m in re.finditer(rb'(?:[\x20-\x7e]\x00){%d,}' % minlen, data):
            out.append(('W', m.start(), m.group().decode('utf-16le', 'replace')))
    return out
target = sys.argv[1]
outp = sys.argv[2]
s = strings(target)
with open(outp,'w',encoding='utf-8') as f:
    for k,off,txt in s:
        f.write(f"{k}\t{off:08x}\t{txt}\n")
print(len(s), "strings ->", outp)
