# Package
version       = "2.2.0"
author        = "Dominik Picheta"
description   = "The Nim forum"
license       = "MIT"

srcDir = "src"

bin = @["forum"]

skipExt = @["nim"]

# Dependencies

requires "nim >= 1.0.6"
requires "httpbeast >= 0.4.0"
requires "jester#405be2e"
requires "bcrypt#440c5676ff6"
requires "hmac#9c61ebe2fd134cf97"
requires "recaptcha#0c471d2"
requires "sass#649e0701fa5c"

requires "karax#45bac6b"

requires "webdriver#429933a"

requires "markdown#568a7cd"

# Tasks

task backend, "Compiles and runs the forum backend":
  exec "nimble c src/forum.nim"
  exec "./src/forum"

task runbackend, "Runs the forum backend":
  exec "./src/forum"

task testbackend, "Runs the forum backend in test mode":
  exec "nimble c -r -d:skipRateLimitCheck src/forum.nim"

task frontend, "Builds the necessary JS frontend (with CSS)":
  exec "nimble c -r src/buildcss"
  exec "nimble js -d:release src/frontend/forum.nim"
  mkDir "public/js"
  cpFile "src/frontend/forum.js", "public/js/forum.js"

task minify, "Minifies the JS using Google's closure compiler":
  exec "./src/minify -o public/css/forum.css public/css/forum.css"
  exec "./src/minify -o public/js/forum.js public/js/forum.js"
  exec "chmod 644 public/js/forum.js public/css/forum.css"

task testdb, "Creates a test DB (with admin account!)":
  exec "nimble c src/setup_nimforum"
  exec "./src/setup_nimforum --test"

task devdb, "Creates a test DB (with admin account!)":
  exec "nimble c src/setup_nimforum"
  exec "./src/setup_nimforum --dev"

task blankdb, "Creates a blank DB":
  exec "nimble c src/setup_nimforum"
  exec "./src/setup_nimforum --blank"

task test, "Runs tester":
  exec "nimble c -y src/forum.nim"
  exec "nimble c -y -r -d:actionDelayMs=0 tests/browsertester"

task fasttest, "Runs tester without recompiling backend":
  exec "nimble c -r -d:actionDelayMs=0 tests/browsertester"
