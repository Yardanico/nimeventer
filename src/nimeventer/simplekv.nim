## This is a very simple and stupid solution
## for saving last activity timestamps (and possibly other data)
## so that, even if nimeventer crashes, the data will be available

import std/[tables, os]

import flatty

type
  SimpleKv* = ref object
    saveLoc: string
    t: Table[string, string]

proc newSimpleKv*(saveLoc: string): SimpleKv = 
  result = SimpleKv(saveLoc: saveLoc)

  if fileExists(saveLoc):
    # Restore the state
    result.t = fromFlatty(readFile(saveLoc), Table[string, string])

proc save(s: SimpleKv) = 
  writeFile(s.saveLoc, s.t.toFlatty())

proc `[]=`*(s: SimpleKv, k, v: string) = 
  s.t[k] = v
  s.save()

func contains*(s: SimpleKv, k: string): bool = 
  s.t.hasKey(k)

func `[]`*(s: SimpleKv, k: string): string = 
  s.t[k]