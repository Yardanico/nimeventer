import std / [
  strutils, httpclient, json, asyncdispatch,
  strformat, with, options, cgi, os
]

import zip/zlib

import ../nimeventer

const
  SoSearchUrl = "https://api.stackexchange.com/2.2/search?order=desc&sort=creation&site=stackoverflow&tagged=$1&key=$2"

var lastActivityStackoverflow*: int64

proc checkStackoverflow*(c: Config): Future[string] {.async.} = 
  let client = newAsyncHttpClient()
  defer: client.close()

  let resp = await client.get(SoSearchUrl.format(c.soTag, encodeUrl(c.soKey)))

  # StackOverflow ALWAYS compresses the API responses with either GZIP or DEFLATE
  # By default they claim to use GZIP
  let cont = uncompress(await resp.body, stream=GZIP_STREAM)
  let jsObj = parseJson(cont)
  let lastPost = jsObj["items"][0]
  let title = lastPost["title"].getStr()
  let url = lastPost["link"].getStr()
  let creationDate = lastPost["creation_date"].getBiggestInt()
  let backoff = jsObj.getOrDefault("backoff")
  # stackoverflow with its throttles :(
  if backoff != nil:
    await sleepAsync(backoff.getInt())

  if creationDate <= lastActivityStackoverflow:
    return
  
  lastActivityStackoverflow = creationDate
  writeFile("last_activity_so", $lastActivityStackoverflow)

  let author = lastPost["owner"]["display_name"].getStr()
  result = fmt"New question by {author}: {title}, see {url}"

proc doStackoverflow*(c: Config) {.async.} = 
  while true:
    catchErr:
      let soCont = await checkStackoverflow(c)
      if soCont != "":
        soCont.post([c.discordWebhook], allTelegramIds, allChans)
      await sleepAsync(c.checkInterval * 1000)

proc initStackoverflow*() = 
  if "last_activity_so".fileExists():
    lastActivityStackoverflow = parseInt(readFile("last_activity_so"))

when isMainModule:
  echo waitFor checkStackoverflow(Config(soTag: "nim-lang"))
