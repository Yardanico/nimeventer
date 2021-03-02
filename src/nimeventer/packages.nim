## Checks for new Nim packages
## Initially I wanted to use nimble.directory but sadly it does not provide 
## repo URL in the RSS feed, so on initialization I get all package names
## and store them in a HashSet, and then on updating check if there's 
## any package name that's not in the list
## This checking also has a lot of safeguards because posting
## >1000 packages is not something I'd like my bot to do
import std/[
  strutils, httpclient, sets, json,
  asyncdispatch, strformat, os
]

import ../nimeventer

const PkgsUrl = "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json"

var pkgNames = initHashSet[string](2048)

proc checkPackages*(c: Config): Future[seq[string]] {.async.} =
  # This returns a seq[string] because we can have
  # multiple new packages in a span of 2 minutes
  # and we don't want to miss them out.
  let c = newAsyncHttpClient()
  defer: c.close()
  let newData = parseJson await c.getContent(PkgsUrl)

  for pkg in newData:
    catchErr:
      let name = pkg{"name"}.getStr()
      if name != "" and name notin pkgNames:
        pkgNames.incl(name)
        let desc = pkg["description"].getStr()
        let url = 
          if "web" in pkg: pkg["web"].getStr()
          else: pkg["url"].getStr()
        result.add fmt"New Nimble package! {name} - {desc}, see {url}"

proc doPackages*(c: Config) {.async.} = 
  while true:
    catchErr:
      let pkgCont = await checkPackages(c)
      
      if pkgCont.len > 7:
        quit("Something's very wrong!")
      
      if pkgCont.len > 0:
        for pkg in pkgCont:
          pkg.post([c.discordWebhook], allTelegramIds, allChans, "[Nimble]")
      
      await sleepAsync(c.checkInterval * 1000)

proc initPackages* = 
  let c = newHttpClient()
  let data = parseJson c.getContent(PkgsUrl)
  # Pre-fetch the package list
  for pkg in data:
    if "name" in pkg:
      pkgNames.incl(pkg["name"].getStr())
  
  # something's wrong, bail out!
  if pkgNames.len < 1000:
    quit("Package names list is too short!")
  
  c.close()