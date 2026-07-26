import re,os,sys
def scan(roots):
    out=[]
    for root in roots:
        for dp,_,fs in os.walk(root):
            if '/target/' in dp or '/src/test/' in dp: continue
            for fn in sorted(fs):
                if not fn.endswith('.java'): continue
                s=open(os.path.join(dp,fn),encoding='utf-8',errors='replace').read()
                if '@Tool' not in s: continue
                m=re.search(r'@McpServer\(\s*"([^"]+)"',s)
                srv=m.group(1) if m else '(default)'
                lines=s.split('\n'); i=0
                while i<len(lines):
                    if re.match(r'\s*@Tool\b',lines[i]):
                        # walk past the annotation's own (possibly multi-line) argument list
                        depth=lines[i].count('(')-lines[i].count(')'); j=i
                        while depth>0 and j+1<len(lines):
                            j+=1; depth+=lines[j].count('(')-lines[j].count(')')
                        j+=1
                        # skip further annotations, comments, blanks
                        while j<len(lines) and (re.match(r'\s*@',lines[j]) or re.match(r'\s*(//|/\*|\*)',lines[j]) or not lines[j].strip()):
                            if re.match(r'\s*@',lines[j]):
                                d=lines[j].count('(')-lines[j].count(')')
                                while d>0 and j+1<len(lines):
                                    j+=1; d+=lines[j].count('(')-lines[j].count(')')
                            j+=1
                        if j<len(lines):
                            mm=re.search(r'\b(\w+)\s*\(',lines[j])
                            if mm: out.append((srv,mm.group(1),fn[:-5]))
                        i=j
                    i+=1
    return sorted(set(out))
for t in scan(sys.argv[1:]): print('\t'.join(t))
