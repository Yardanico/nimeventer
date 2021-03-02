import std/[
  asyncdispatch, uri,
  strutils, options,
  json, httpclient
]

import irc

import nimeventer/simplekv
export simplekv

type
  Config* = object
    save_file*: string
    base_url*: string
    reddit_url*: string
    so_tag*: string
    so_key*: string
    max_context_len*: int
    check_interval*: int
    irc_nickname*: string
    irc_password*: string
    irc_chans*: seq[string]
    irc_full_chans*: seq[string]
    telegram_ids*: seq[string]
    telegram_full_ids*: seq[string]
    discord_webhook*: string
    telegram_url*: string

var 
  config: Config
  client: AsyncIrc # IRC client instance
  allChans*: seq[string] # IRC channels to send all updates to
  allTelegramIds*: seq[string] # Telegram channels to send all updates to
  kdb*: SimpleKv

proc postToDiscord(webhook, content, service: string) {.async.} = 
  let client = newAsyncHttpClient()
  client.headers = newHttpHeaders({"Content-Type": "application/json"})
  var username = "NimEventer"
  if service != "": username.add service
  let data = $(
    %*{
      "username": username, 
      "content": content
    }
  )
  let resp = await client.post(webhook, data)
  client.close()

proc postToTelegram(id, content: string) {.async.} = 
  let chan = id.encodeUrl()
  let client = newAsyncHttpClient()
  let resp = await client.get(config.telegramUrl % [chan, content.encodeUrl()])
  client.close()

proc onIrcEvent(client: AsyncIrc, event: IrcEvent) {.async.} =
  case event.typ
  of EvDisconnected, EvTimeout:
    await client.reconnect()
  else:
    discard

proc post*(content: string, disc, telegram, irc: openArray[string], service = "") = 
  for webhook in disc:
    asyncCheck webhook.postToDiscord(content, service)
  for chan in telegram:
    asyncCheck chan.postToTelegram content
  for chan in irc:
    asyncCheck client.privmsg(chan, content)
  echo content

template catchErr*(body: untyped) =
  try:
    body
  except:
    echo "!!!!!got exception!!!!!"
    let e = getCurrentException()
    echo e.getStackTrace()
    echo e.msg
    echo "!!!!!!!!!!!!!!!!!!!!!!!"

import nimeventer/[nimforum, reddit, stackoverflow]

proc check {.async.} = 
  client = newAsyncIrc(
    address = "irc.freenode.net", 
    port = Port(6667),
    nick = config.ircNickname,
    serverPass = config.ircPassword,
    joinChans = allChans, 
    callback = onIrcEvent
  )
  await client.connect()

  asyncCheck client.run()
  # give irc client 10 seconds to init
  await sleepAsync(10000)
  asyncCheck doForum(config)
  asyncCheck doStackoverflow(config)
  asyncCheck doReddit(config)

proc main = 
  config = parseFile("config.json").to(Config)
  kdb = newSimpleKv(config.saveFile)
  allChans = config.ircChans & config.ircFullChans
  allTelegramIds = config.telegramIds & config.telegramFullIds
  
  initForum()
  initStackoverflow()
  initReddit()

  asyncCheck check()
  runForever()

main()