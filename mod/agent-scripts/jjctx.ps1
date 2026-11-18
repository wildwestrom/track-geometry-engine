# Windows counterpart of jjctx: jj st, the last N (default 6) changes, and a diffstat of the
# working copy.  jjctx.ps1 [N]
param([int]$N = 6)
"== status"; jj st
"== log"; jj log -n $N
"== diff --stat"; jj diff --stat
