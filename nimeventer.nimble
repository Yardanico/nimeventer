version       = "0.2.0"
author        = "Danil Yarantsev (Yardanico)"
description   = "Nimeventer - Posts updates from various Nim communities to various Nim communities :)"
license       = "MIT"
srcDir        = "src"
bin           = @["nimeventer"]

requires "nim >= 1.2.0"
requires "irc" # post to irc
requires "zippy" # stackoverflow gzip
requires "flatty" # serializing last activity states