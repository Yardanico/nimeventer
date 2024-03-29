import std/[
  httpclient, asyncdispatch, strformat,
  htmlparser, strutils, xmltree,
  options, json, os
]

import ../nimeventer

type
  Post = object
    id: int
    author: string
    shouldIgnore: bool
    startContext: string
    created: int64
  
  ForumThread = object
    id: int
    activity: int64
    author: string
    title: string
    posts: seq[Post]

proc getContextForPost(c: Config, cont: string): string = 
  let processed = cont.strip().parseHtml()
  var postText = ""
  # This code is for parsing HTML of the posts:
  # Sometimes the "blockquote" (used for quotes) tag doesn't contain
  # the actual quote inside, in which case it comes AFTER the tag.
  # So if we find an empty blockquote - we assume 
  # that the next paragraph is a quote
  var nextIsQuote = false
  for item in processed:
    if nextIsQuote:
      nextIsQuote = false
      continue
    if item.kind == xnElement and item.tag == "blockquote":
      if item.innerText.strip() == "":
        nextIsQuote = true
    else:
      postText.add item.innerText & " "
  
  let postWords = postText.strip().split(Whitespace)
  var res: seq[string]
  var curLen = 0
  var fullText = true
  # We limit the context to be maximum of MaxContextLen, but
  # we do it over the words so we have whole words in the context
  for word in postWords:
    inc(curLen, word.len)
    if curLen > c.maxContextLen: 
      fullText = false
      break
    res.add word
  
  result = res.join(" ").strip()
  # Only add ... when we still have stuff left in the message
  # (just for nicer look of short posts)
  if not fullText: result &= " ..."

proc getLastThread(c: Config): Future[Option[ForumThread]] {.async.} = 
  var client = newAsyncHttpClient()
  var resp = await client.get(c.baseUrl & "threads.json")
  if resp.code != Http200: 
    client.close()
    return
  
  let thrbody = parseJson(await resp.body)
  # We do this to skip pinned threads since it's assumed they get enough
  # activity anyway, and there's no easy way to make new posts for pinned threads
  # work without reworking how we store posted events (so it's a TODO)
  var lastThr: JsonNode
  for thread in thrbody["threads"]:
    if not thread["isPinned"].getBool():
      lastThr = thread
      break
  
  # just in case
  if lastThr.len == 0:
    echo "what? no non-pinned threads?"
    return
  var thread = ForumThread(
    id: lastThr["id"].getInt(),
    activity: lastThr["activity"].getInt(),
    title: lastThr["topic"].getStr()
  )
  
  resp = await client.get(c.baseUrl & fmt"posts.json?id={thread.id}")
  if resp.code != Http200:
    client.close()
    return
  
  let postsBody = await resp.body
  client.close()
  
  let posts = postsBody.parseJson()["posts"]
  for i, post in posts.elems:
    # first post is always the thread starting one, so we set
    # the author here
    if i == 0:
      thread.author = post["author"]["name"].getStr()
    
    const badRanks = ["Spammer", "Moderated", "Troll", "Banned"]
    thread.posts.add Post(
      id: post["id"].getInt(),
      author: post["author"]["name"].getStr(),
      shouldIgnore: post["author"]["rank"].getStr() in badRanks,
      created: post["info"]["creation"].getInt(),
      startContext: getContextForPost(c, post["info"]["content"].getStr())
    )
  
  result = some thread

proc checkNimforum(c: Config) {.async.} = 
  echo "Checking..."
  let newThreadMaybe = await getLastThread(c)
  # For HTTP errors (forum can sometimes send codes like 502)
  if not newThreadMaybe.isSome(): 
    return
  
  let newThread = newThreadMaybe.get()
  let newPost = newThread.posts[^1]

  # Ignore new posts from banned / moderated / etc users and verify
  # that the new post was created later than the last post we checked
  if newPost.shouldIgnore or parseInt(kdb["forumLastActivity"]) >= newPost.created:
    return
  # We write the last timestamp so that after restart we don't spam
  # with the same threads / posts
  kdb["forumLastActivity"] = $newPost.created

  let threadTitle = newThread.title.capitalizeAscii()
  let threadAuthor = newThread.author
  let threadLink = fmt"{c.baseUrl}t/{newThread.id}"
  let postLink = fmt"{c.baseUrl}t/{newThread.id}#{newPost.id}"
  let postAuthor = newPost.author
  let postContext = newPost.startContext
  
  # We already know about that post (or thread)
  if newPost.id == parseInt(kdb["forumLastPost"]): return
  # Save the ID of the last post and immediately write it to the file
  kdb["forumLastPost"] = $newPost.id
  
  # Only 1 post -> new thread, post everywhere
  if newThread.posts.len == 1:
    fmt("New thread by {threadAuthor}: {threadTitle}, see {threadLink}").post(
      [c.discordWebhook], allTelegramIds, allChans, "[Forum]"
    )
  # More than 1 post -> new post, don't post in some communities
  else:
    fmt("New post by {postAuthor} in {threadTitle}: {postContext} ({postLink})").post(
      [c.discordWebhook], c.telegramFullIds, c.ircFullChans, "[Forum]"
    )

proc doForum*(c: Config) {.async.} = 
  while true:
    catchErr:
      await checkNimforum(c)
      await sleepAsync(c.checkInterval * 1000)

proc initForum*() = 
  # Some info to not re-post on restart
  if "forumLastActivity" notin kdb:
    kdb["forumLastActivity"] = "0"
  
  if "forumLastPost" notin kdb:
    kdb["forumLastPost"] = "0"
