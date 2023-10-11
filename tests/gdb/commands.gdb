set pagination off
set disassembly-flavor intel
starti
source ./callback.py
python setbp()
run
continue
quit
