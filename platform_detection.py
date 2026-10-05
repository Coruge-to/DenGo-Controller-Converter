import ctypes
import time
from ctypes import wintypes
from dataclasses import dataclass
TH32CS_SNAPPROCESS=2
PROCESS_QUERY_LIMITED_INFORMATION=0x1000
INVALID_HANDLE_VALUE=ctypes.c_void_p(-1).value
TARGET_NAMES={"bvets.exe","pcsx2.exe","pcsx2-qt.exe","rpcs3.exe","jreast_trainsimulator.exe","runningtrain-win64-shipping.exe"}
kernel32=ctypes.windll.kernel32
user32=ctypes.windll.user32
class PROCESSENTRY32W(ctypes.Structure):
 _fields_=[("dwSize",wintypes.DWORD),("cntUsage",wintypes.DWORD),("th32ProcessID",wintypes.DWORD),("th32DefaultHeapID",ctypes.c_size_t),("th32ModuleID",wintypes.DWORD),("cntThreads",wintypes.DWORD),("th32ParentProcessID",wintypes.DWORD),("pcPriClassBase",wintypes.LONG),("dwFlags",wintypes.DWORD),("szExeFile",wintypes.WCHAR*260)]
@dataclass(frozen=True)
class PlatformStatus:
 platform_id:str;display_name:str;running:bool;process_ids:tuple;window_titles:tuple
PLATFORMS=(("jrets","JRETS"),("bve5","BVE5"),("bve6","BVE6"),("pcsx2","PCSX2"),("rpcs3","RPCS3"),("running_train","RUNNING TRAIN"))
def _target_processes():
 s=kernel32.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0)
 if s==INVALID_HANDLE_VALUE:return ()
 v=[]
 try:
  e=PROCESSENTRY32W();e.dwSize=ctypes.sizeof(PROCESSENTRY32W);ok=kernel32.Process32FirstW(s,ctypes.byref(e))
  while ok:
   n=str(e.szExeFile)
   if n.lower() in TARGET_NAMES:v.append((int(e.th32ProcessID),n))
   ok=kernel32.Process32NextW(s,ctypes.byref(e))
 finally:kernel32.CloseHandle(s)
 return tuple(v)
def _path(pid):
 h=kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,False,pid)
 if not h:return ""
 try:
  z=wintypes.DWORD(32768);b=ctypes.create_unicode_buffer(z.value);return b.value if kernel32.QueryFullProcessImageNameW(h,0,b,ctypes.byref(z)) else ""
 finally:kernel32.CloseHandle(h)
def _windows(pids):
 r={};pids=set(pids);T=ctypes.WINFUNCTYPE(wintypes.BOOL,wintypes.HWND,wintypes.LPARAM)
 def cb(hwnd,_):
  if not user32.IsWindowVisible(hwnd):return True
  p=wintypes.DWORD();user32.GetWindowThreadProcessId(hwnd,ctypes.byref(p));p=int(p.value)
  if p not in pids:return True
  n=user32.GetWindowTextLengthW(hwnd);tb=ctypes.create_unicode_buffer(n+1);user32.GetWindowTextW(hwnd,tb,n+1);c=ctypes.create_unicode_buffer(256);user32.GetClassNameW(hwnd,c,256);r.setdefault(p,[]).append((tb.value,c.value));return True
 user32.EnumWindows(T(cb),0);return r
def _classify(n,path,ws):
 n=n.lower();path=path.lower()
 if n=="bvets.exe":
  if "\\mackoy\\bvets5\\bvets.exe" in path:return "bve5"
  if "\\mackoy\\bvets6\\bvets.exe" in path:return "bve6"
 if n in ("pcsx2.exe","pcsx2-qt.exe"):return "pcsx2"
 if n=="rpcs3.exe":return "rpcs3"
 if n=="jreast_trainsimulator.exe":return "jrets"
 if n=="runningtrain-win64-shipping.exe" and any(c=="UnrealWindow" for _,c in ws):return "running_train"
def _scan(ps):
 w=_windows(pid for pid,_ in ps);f={p:[] for p,_ in PLATFORMS};u=False
 for pid,n in ps:
  ws=w.get(pid,[])
  if not ws:u=True;continue
  q=_classify(n,_path(pid),ws)
  if q:f[q].append((pid,tuple(t for t,_ in ws if t)))
 return tuple(PlatformStatus(p,l,bool(f[p]),tuple(e[0] for e in f[p]),tuple(t for e in f[p] for t in e[1])) for p,l in PLATFORMS),u
class EfficientPlatformDetector:
 def __init__(self,probe_interval=.2,full_resync_interval=3.):self.probe_interval=probe_interval;self.full_resync_interval=full_resync_interval;self.a=0.;self.b=0.;self.s=None;self.u=True;self.v=tuple(PlatformStatus(p,n,False,(),()) for p,n in PLATFORMS)
 def update(self):
  now=time.monotonic()
  if now-self.a<self.probe_interval:return self.v
  self.a=now;ps=_target_processes();s=tuple(sorted((p,n.lower()) for p,n in ps))
  if s!=self.s or now-self.b>=self.full_resync_interval or self.u:self.v,self.u=_scan(ps);self.s=s;self.b=now
  return self.v
