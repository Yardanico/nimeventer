import std/[
  strutils, httpclient, json, asyncdispatch,
  strformat, cgi, options, os
]

import zippy

import ../nimeventer

const
  SoSearchUrl = "https://api.stackexchange.com/2.2/search?order=desc&sort=creation&site=stackoverflow&tagged=$1&key=$2"

proc checkStackoverflow*(c: Config): Future[string] {.async.} = 
  let client = newAsyncHttpClient()
  defer: client.close()

  let resp = await client.get(SoSearchUrl % [c.soTag, encodeUrl(c.soKey)])

  # Uncompress gzipped response
  let body = await resp.body
  let jsObj = parseJson(uncompress(body))
  let lastPost = jsObj["items"][0]
  let title = lastPost["title"].getStr()
  let url = lastPost["link"].getStr()
  let creationDate = lastPost["creation_date"].getBiggestInt()
  let backoff = jsObj.getOrDefault("backoff")
  # stackoverflow with its throttles :(
  if backoff != nil:
    await sleepAsync(backoff.getInt())

  if creationDate <= parseInt(kdb["soLastActivity"]):
    return
  
  kdb["soLastActivity"] = $creationDate

  let author = lastPost["owner"]["display_name"].getStr()
  result = fmt"New question by {author}: {title}, see {url}"

proc doStackoverflow*(c: Config) {.async.} = 
  while true:
    catchErr:
      let soCont = await checkStackoverflow(c)
      if soCont != "":
        soCont.post([c.discordWebhook], allTelegramIds, allChans, "[Stackoverflow]")
      await sleepAsync(c.checkInterval * 1000)

proc initStackoverflow*() = 
  if "soLastActivity" notin kdb:
    kdb["soLastActivity"] = "0"

when isMainModule:
  echo waitFor checkStackoverflow(Config(soTag: "nim-lang"))
