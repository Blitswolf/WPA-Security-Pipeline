import os, hmac, hashlib, struct
from scapy.all import Dot11, Dot11Beacon, Dot11Elt, LLC, SNAP, wrpcap, Raw
essid=b"PIPELINE-TEST"; pw=b"password"
ap="02:00:de:ad:be:ef"; sta="02:00:ca:fe:ba:be"
apb=bytes.fromhex(ap.replace(":","")); stab=bytes.fromhex(sta.replace(":",""))
anonce=os.urandom(32); snonce=os.urandom(32)
pmk=hashlib.pbkdf2_hmac("sha1",pw,essid,4096,32)
def prf512(pmk,A,B):
    r=b""; i=0
    while len(r)<64:
        r+=hmac.new(pmk,A+b"\x00"+B+bytes([i]),hashlib.sha1).digest(); i+=1
    return r[:64]
blob=min(apb,stab)+max(apb,stab)+min(anonce,snonce)+max(anonce,snonce)
kck=prf512(pmk,b"Pairwise key expansion",blob)[:16]
def ek(ki,nonce,rc,mic=b"\x00"*16,kd=b""):
    body=struct.pack("!B",2)+struct.pack("!H",ki)+struct.pack("!H",16)+struct.pack("!Q",rc)
    body+=nonce+b"\x00"*16+b"\x00"*8+b"\x00"*8+mic+struct.pack("!H",len(kd))+kd
    return struct.pack("!BBH",1,3,len(body))+body
m1=ek(0x008a,anonce,1)
m2n=ek(0x010a,snonce,1)
mic=hmac.new(kck,m2n,hashlib.sha1).digest()[:16]
m2=ek(0x010a,snonce,1,mic=mic)
bcn=Dot11(type=0,subtype=8,addr1="ff:ff:ff:ff:ff:ff",addr2=ap,addr3=ap)/Dot11Beacon()/Dot11Elt(ID="SSID",info=essid)
f1=Dot11(type=2,subtype=0,FCfield="from-DS",addr1=sta,addr2=ap,addr3=ap)/LLC(dsap=0xaa,ssap=0xaa,ctrl=3)/SNAP(code=0x888e)/Raw(load=m1)
f2=Dot11(type=2,subtype=0,FCfield="to-DS",addr1=ap,addr2=sta,addr3=ap)/LLC(dsap=0xaa,ssap=0xaa,ctrl=3)/SNAP(code=0x888e)/Raw(load=m2)
wrpcap("%s/pipeline-test.cap"%os.path.dirname(os.path.abspath(__file__)),[bcn,f1,f2])
print("wrote pipeline-test.cap  essid=PIPELINE-TEST pw=password ap=%s sta=%s"%(ap,sta))
