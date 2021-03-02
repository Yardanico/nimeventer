import std/[
  strutils, httpclient, json, 
  asyncdispatch, strformat, options, os
]

import ../nimeventer

#const RedditUrl = "https://www.reddit.com/r/nim/new.json"


proc checkReddit*(c: Config): Future[string] {.async.} = 
  let client = newAsyncHttpClient()
  defer: client.close()
  let resp = await client.get(c.redditUrl)
  if resp.code != Http200:
    return
  let obj = parseJson(await resp.body)

  let lastEntity = obj["data"]["children"].getElems()[0]
  let data = lastEntity["data"]
  #echo data.pretty()

  let id = data["id"].getStr()
  let title = data["title"].getStr()
  let author = data["author"].getStr()
  let created = data["created_utc"].getFloat().toInt()
  # if the post was created earlier or it's the same one we that posted before
  if created <= parseInt(kdb["redditLastActivity"]):
    return

  kdb["redditLastActivity"] = $created
  var commentsUrl = "https://reddit.com" & data["permalink"].getStr()
  result = fmt"New post on r/nim by {author}: {title}, see {commentsUrl}"

proc doReddit*(c: Config) {.async.} = 
  while true:
    catchErr:
      let redditCont = await checkReddit(c)
      if redditCont != "":
        redditCont.post([c.discordWebhook], allTelegramIds, allChans, "[Reddit]")
      await sleepAsync(c.checkInterval * 1000)

proc initReddit* = 
  if "redditLastActivity" notin kdb:
    kdb["redditLastActivity"] = "0"

when isMainModule:
  waitFor doReddit(Config(redditUrl: "https://www.reddit.com/r/nim/new.json"))