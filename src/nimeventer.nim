import std / [
  os, asyncdispatch,
  times, uri,
  strformat, strutils, options,
  json, htmlparser, xmltree, 
  httpclient
]

import irc

type
  Post = object
    id: int
    author: string
    startContext: string
    created: Time
  
  ForumThread = object
    id: int
    activity: Time
    author: string
    title: string
    posts: seq[Post]
  
  Config = object
    base_url: string
    threads_url: string
    posts_url: string
    max_context_len: int
    check_interval: int
    irc_nickname: string
    irc_password: string
    irc_chan: string
    discord_webhook: string
    telegram_url: string

var config: Config

proc postToDiscord(webhook, content: string) {.async.} = 
  let client = newAsyncHttpClient()
  client.headers = newHttpHeaders({"Content-Type": "application/json"})
  let data = $(
    %*{
      "username": "ForumUpdater", 
      "content": content
    }
  )
  let resp = await client.post(webhook, data)
  client.close()

proc postToTelegram(content: string) {.async.} = 
  let chan = "@nim_lang".encodeUrl()
  let client = newAsyncHttpClient()
  let resp = await client.get(config.telegramUrl % [chan, content.encodeUrl()])

proc getContextForPost(cont: string): string = 
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
    if curLen > config.maxContextLen: 
      fullText = false
      break
    res.add word
  
  result = res.join(" ").strip()
  # Only add ... when we still have stuff left in the message
  # (just for nicer look of short posts)
  if not fullText: result &= " ..."

proc getLastThread(): Future[Option[ForumThread]] {.async.} = 
  var client = newAsyncHttpClient()
  var resp = await client.get(config.threadsUrl)
  if resp.code != Http200: 
    return
  
  let thrbody = await resp.body
  let lastThr = thrbody.parseJson()["threads"][0]
  var thread = ForumThread(
    id: lastThr["id"].getInt(),
    activity: lastThr["activity"].getInt().fromUnix(),
    title: lastThr["topic"].getStr()
  )
  
  resp = await client.get(config.postsUrl & $thread.id)
  if resp.code != Http200: 
    return
  
  let postsBody = await resp.body
  
  let posts = postsBody.parseJson()["posts"]
  for i, post in posts.elems:
    # first post is always the thread starting one, so we set
    # the author here
    if i == 0:
      thread.author = post["author"]["name"].getStr()
    
    thread.posts.add Post(
      id: post["id"].getInt(),
      author: post["author"]["name"].getStr(),
      created: post["info"]["creation"].getInt().fromUnix(),
      startContext: getContextForPost(post["info"]["content"].getStr())
    )
  
  result = some thread

var 
  lastThread: ForumThread
  lastPost: Post
  lastActivity: Time
  client: AsyncIrc

proc onIrcEvent(client: AsyncIrc, event: IrcEvent) {.async.} =
  case event.typ
  of EvDisconnected, EvTimeout:
    await client.reconnect()
  else:
    discard

proc check {.async.} = 
  client = newAsyncIrc(
    address = "irc.freenode.net", 
    port = Port(6667),
    nick = config.ircNickname,
    serverPass = config.ircPassword,
    joinChans = @[config.ircChan], 
    callback = onIrcEvent
  )
  await client.connect()
  asyncCheck client.run()

  while true: 
    await sleepAsync(config.checkInterval * 1000)
    echo "Checking..."
    let newThreadMaybe = await getLastThread()
    # For HTTP errors (forum can sometimes send codes like 502)
    if not newThreadMaybe.isSome(): 
      continue
    
    let newThread = newThreadMaybe.get()
    let newPost = newThread.posts[^1]

    # Either nothing changed (==) or someone removed the last post
    # or thread (>), both of which will be caught here. 
    if lastActivity >= newPost.created:
      continue
    lastActivity = newPost.created

    # We write the last timestamp so that after restart we don't spam
    # with the same threads / posts
    writeFile("last_activity", $lastActivity.toUnix())

    let threadTitle = newThread.title.capitalizeAscii()
    let threadAuthor = newThread.author.capitalizeAscii()
    let threadLink = &"{config.baseUrl}t/{newThread.id}"
    let postLink = &"{config.baseUrl}t/{newThread.id}#{newPost.id}"
    let postAuthor = newPost.author.capitalizeAscii()
    let postContext = newPost.startContext
    
    # We still need to update, because we might've read new thread id
    # from the file and all other fields are empty
    if lastThread.id == newThread.id:
      lastThread = newThread
    
    # Only 1 post -> new thread
    elif newThread.posts.len == 1:
      lastThread = newThread
      let content = &"New thread by {threadAuthor}: {threadTitle}, see {threadLink}"
      for webhook in [config.discordWebhook]:
        asyncCheck webhook.postToDiscord content
      asyncCheck postToTelegram content
      asyncCheck client.privmsg(config.ircChan, content)
      writeFile("last_thread", $lastThread.id)
    
    # We have a "new" thread with more than 1 post
    else:
      # If we already know about the last post - ignore
      if lastPost.id == newPost.id: continue

      lastPost = newPost
      let content = &"New post by {postAuthor} in {threadTitle}: {postContext} ({postLink})"
      for webhook in [config.discordWebhook]:
        asyncCheck webhook.postToDiscord content
      asyncCheck postToTelegram content
      asyncCheck client.privmsg(config.ircChan, content)

proc main = 
  config = parseFile("config.json").to(Config)
  # Read some "config" files first :)
  if "last_activity".fileExists():
    lastActivity = parseInt(readFile("last_activity")).fromUnix()
  
  if "last_thread".fileExists():
    lastThread.id = parseInt(readFile("last_thread"))

  waitFor check()

main()