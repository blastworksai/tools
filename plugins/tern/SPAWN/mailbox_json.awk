# POSIX awk strict JSON lexical gate for mailbox_worker.sh. LC_ALL=C; iconv
# validates UTF-8 first. No nulls, duplicate decoded keys, trailing data or BOM.
function fail() { bad=1; exit 1 }
function ws() { while (substr(s,p,1) ~ /^[ \t\r\n]$/ && p<=length(s)) p++ }
function hex4( x,i,c,n) {
 x=substr(s,p,4); if(length(x)!=4) fail(); n=0
 for(i=1;i<=4;i++){c=index("0123456789abcdef",tolower(substr(x,i,1)))-1;if(c<0)fail();n=n*16+c}
 p+=4; return n
}
function utf(n) {
 if(n<128)return sprintf("%c",n)
 if(n<2048)return sprintf("%c%c",192+int(n/64),128+n%64)
 if(n<65536)return sprintf("%c%c%c",224+int(n/4096),128+int(n/64)%64,128+n%64)
 return sprintf("%c%c%c%c",240+int(n/262144),128+int(n/4096)%64,128+int(n/64)%64,128+n%64)
}
function string_value( out,c,n,low) {
 if(substr(s,p++,1)!="\"")fail();out=""
 while(p<=length(s)){
  c=substr(s,p++,1)
  if(c=="\""){if(length(out)>(journal?1572864:32768))fail();return out}
  if(c ~ /[\001-\037]/ || c==sprintf("%c",0))fail()
  if(c=="\\"){
   c=substr(s,p++,1)
   if(c=="u"){
    n=hex4()
    if(n>=55296&&n<=56319){if(substr(s,p,2)!="\\u")fail();p+=2;low=hex4();if(low<56320||low>57343)fail();n=65536+(n-55296)*1024+low-56320}
    else if(n>=56320&&n<=57343)fail()
    c=utf(n)
   }else if(c=="b")c=sprintf("%c",8)
   else if(c=="f")c=sprintf("%c",12)
   else if(c=="n")c="\n"
   else if(c=="r")c="\r"
   else if(c=="t")c="\t"
   else if(c!="\""&&c!="\\"&&c!="/")fail()
  }
  out=out c
 }
 fail()
}
function value(depth, c,obj,key,count,tail,n) {
 if(depth>12||++values>(journal?16384:2048))fail();ws();c=substr(s,p,1)
 if(c=="\""){string_value();return}
 if(c=="{"||c=="["){
  p++;obj=++objects;count=0;ws()
  if(substr(s,p,1)==(c=="{"?"}":"]")){p++;return}
  while(1){
   if(++count>(c=="{"?64:256))fail();ws()
   if(c=="{"){key=string_value();if(length(key)>64||((obj SUBSEP key)in seen))fail();seen[obj SUBSEP key]=1;ws();if(substr(s,p++,1)!=":")fail()}
   value(depth+1);ws()
   if(substr(s,p,1)==(c=="{"?"}":"]")){p++;return}
   if(substr(s,p++,1)!=",")fail()
  }
 }
 if(substr(s,p,4)=="true"){p+=4;return}
 if(substr(s,p,5)=="false"){p+=5;return}
 tail=substr(s,p)
 if(match(tail,/^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/)){
  n=substr(tail,1,RLENGTH)+0;if(n>1.7976931348623157e308||n< -1.7976931348623157e308)fail();p+=RLENGTH;return
 }
 fail()
}
{if(NR>1)s=s "\n";s=s $0;if(length(s)>(journal?1572864:65536))fail()}
END {if(bad)exit 1;p=1;value(1);ws();if(p<=length(s))exit 1}
