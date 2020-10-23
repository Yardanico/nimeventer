import std / [
  strutils, httpclient, json, asyncdispatch,
  strformat, with, options
]

import zip/zlib

const
  SoSearchUrl = "https://api.stackexchange.com/2.2/search?order=desc&sort=creation&site=stackoverflow&tagged="

var lastActivityStackoverflow*: int64

proc checkStackoverflow*(soTag: string): Future[string] {.async.} = 
  let client = newAsyncHttpClient()
  defer: client.close()

  let resp = await client.get(SoSearchUrl & soTag)

  # StackOverflow ALWAYS compresses the API responses with either GZIP or DEFLATE
  # By default they claim to use GZIP
  let cont = uncompress(await resp.body, stream=GZIP_STREAM)
  let lastPost = parseJson(cont)["items"][0]
  let title = lastPost["title"].getStr()
  let url = lastPost["link"].getStr()
  let creationDate = lastPost["creation_date"].getBiggestInt()

  if creationDate <= lastActivityStackoverflow:
    return
  
  lastActivityStackoverflow = creationDate
  writeFile("last_activity_so", $lastActivityStackoverflow)

  let author = lastPost["owner"]["display_name"].getStr()
  result = fmt"New question by {author}: {title}, see {url}"


when isMainModule:
  echo waitFor checkStackoverflow("nim-lang")