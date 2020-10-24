import std / [
  httpclient, asyncdispatch, strformat,
  times, htmlparser, strutils, xmltree,
  options, json, os
]


import ../nimeventer

type
  Post = object
    id: int
    author: string
    shouldIgnore: bool
    startContext: string
    created: Time
  
  ForumThread = object
    id: int
    activity: Time
    author: string
    title: string
    posts: seq[Post]

var
  lastPostId: int # ID of the last post we handled
  lastActivity: Time # timestamp of the last "activity" we handled

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
  var resp = await client.get(c.threadsUrl)
  if resp.code != Http200: 
    client.close()
    return
  
  let thrbody = await resp.body
  let lastThr = thrbody.parseJson()["threads"][0]
  var thread = ForumThread(
    id: lastThr["id"].getInt(),
    activity: lastThr["activity"].getInt().fromUnix(),
    title: lastThr["topic"].getStr()
  )
  
  resp = await client.get(c.postsUrl & $thread.id)
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
      created: post["info"]["creation"].getInt().fromUnix(),
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
  if newPost.shouldIgnore or lastActivity >= newPost.created:
    return
  lastActivity = newPost.created

  # We write the last timestamp so that after restart we don't spam
  # with the same threads / posts
  writeFile("last_activity_forum", $lastActivity.toUnix())

  let threadTitle = newThread.title.capitalizeAscii()
  let threadAuthor = newThread.author.capitalizeAscii()
  let threadLink = fmt"{c.baseUrl}t/{newThread.id}"
  let postLink = fmt"{c.baseUrl}t/{newThread.id}#{newPost.id}"
  let postAuthor = newPost.author.capitalizeAscii()
  let postContext = newPost.startContext
  
  # We already know about that post (or thread)
  if newPost.id == lastPostId: return
  # Save the ID of the last post and immediately write it to the file
  lastPostId = newPost.id
  writeFile("last_post", $lastPostId)
  
  # Only 1 post -> new thread, post everywhere
  if newThread.posts.len == 1:
    fmt("New thread by {threadAuthor}: {threadTitle}, see {threadLink}").post(
      [c.discordWebhook], allTelegramIds, allChans
    )
  # More than 1 post -> new post, don't post in some communities
  else:
    fmt("New post by {postAuthor} in {threadTitle}: {postContext} ({postLink})").post(
      [c.discordWebhook], c.telegramFullIds, c.ircFullChans
    )

proc doForum*(c: Config) {.async.} = 
  while true:
    catchErr:
      await sleepAsync(c.checkInterval * 1000)
      await checkNimforum(c)

proc initForum*() = 
  # Some info to not re-post on restart
  if "last_activity_forum".fileExists():
    lastActivity = parseInt(readFile("last_activity_forum")).fromUnix()
  
  if "last_post".fileExists():
    lastPostId = parseInt(readFile("last_post"))