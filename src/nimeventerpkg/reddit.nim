import std / [
  strutils, httpclient, json, asyncdispatch,
  times, strformat, with, options
]

#const RedditUrl = "https://www.reddit.com/r/nim/new.json"

var lastActivityReddit: Time

proc checkReddit*(url: string): Future[string] {.async.} = 
  let client = newAsyncHttpClient()
  defer: client.close()
  let resp = await client.get(url)
  if resp.code != Http200:
    return
  let obj = parseJson(await resp.body)

  let lastEntity = obj["data"]["children"].getElems()[0]
  let data = lastEntity["data"]
  #echo data.pretty()

  let id = data["id"].getStr()
  let title = data["title"].getStr()
  let author = data["author"].getStr()
  let created = data["created_utc"].getfloat().fromUnixFloat()
  # if the post was created earlier or it's the same one we that posted before
  if created <= lastActivityReddit:
    return
  lastActivityReddit = created
  writeFile("last_activity_reddit", $lastActivityReddit.toUnix())
  var commentsUrl = data["url"].getStr()
  when false:
    with commentsUrl:
      delete(len(commentsUrl) - 1, 999)
      add(".json")
    
    let commResp = await client.get(commentsUrl)
    let postData = parseJson(await commResp.body)
  result = fmt"New post on r/nim by {author}: {title}, see {commentsUrl}"

when isMainModule:
  proc main {.async.} = 
    while true:
      let data = await checkReddit("https://www.reddit.com/r/nim/new.json")
      if data != "":
        echo data
      await sleepAsync(1000)
  waitFor main()