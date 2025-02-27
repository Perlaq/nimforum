#
#
#              The Nim Forum
#        (c) Copyright 2012 Andreas Rumpf, Dominik Picheta
#        Look at license.txt for more info.
#        All rights reserved.
#
import system except Thread
import
  os, strutils, times, md5, strtabs, math, db_sqlite,
  jester, asyncdispatch, asyncnet, sequtils,
  parseutils, random, rst, recaptcha, json, re, sugar,
  strformat, logging, markdown
import cgi except setCookie
import options

import auth, email, utils, buildcss

import frontend/threadlist except User
import frontend/userlist except User
import frontend/[
  category, postlist, pmlist, error, header, post, profile, user, karaxutils, search
]

from htmlgen import tr, th, td, span, input

#when not declared(roSandboxDisabled):
#  {.error: "Your Nim version is vulnerable to a CVE. Upgrade it.".}

type
  TCrud = enum crCreate, crRead, crUpdate, crDelete

  Session = object of RootObj
    userName, userPass, email: string
    rank: Rank
    previousVisitAt: int64

  TForumData = ref object of Session
    req: Request
    userid: string
    config: Config

var
  db: DbConn
  isFTSAvailable: bool
  config: Config
  captcha: ReCaptcha
  mailer: Mailer
  karaxHtml: string

proc init(c: TForumData) =
  c.userPass = ""
  c.userName = ""

  c.userid = ""

proc loggedIn(c: TForumData): bool =
  result = c.userName.len > 0

# --------------- HTML widgets ------------------------------------------------


proc genThreadUrl(c: TForumData, postId = "", action = "",
                  threadid = ""): string =
  result = "/t/" & threadid
  if action != "":
    result.add("?action=" & action)
    if postId != "":
      result.add("&postid=" & postid)
  elif postId != "":
    result.add("#" & postId)
  result = c.req.makeUri(result, absolute = false)


proc getGravatarUrl(email: string, size = 80): string =
  let emailMD5 = email.toLowerAscii.toMD5
  return ("https://www.gravatar.com/avatar/" & $emailMD5 & "?s=" & $size &
     "&d=identicon")



# -----------------------------------------------------------------------------

proc validateCaptcha(recaptchaResp, ip: string) {.async.} =
  # captcha validation:
  if config.recaptchaSecretKey.len > 0:
    var verifyFut = captcha.verify(recaptchaResp, ip)
    yield verifyFut
    if verifyFut.failed:
      raise newForumError(
        "Invalid recaptcha answer", @[]
      )

proc sendResetPassword(
  c: TForumData,
  email: string,
  recaptchaResp: string,
  userIp: string
) {.async.} =
  # Gather some extra information to determine ident hash.
  let row = db.getRow(
    sql"""
      select name, password, email, salt from person
      where email = ? or name = ?
    """,
    email, email
  )
  if row[0] == "":
    raise newForumError("Email or username not found", @["email"])

  if not c.loggedIn:
    await validateCaptcha(recaptchaResp, userIp)

  await sendSecureEmail(
    mailer,
    ResetPassword, c.req,
    row[0], row[1], row[2], row[3]
  )

proc logout(c: TForumData) =
  const query = sql"delete from session where key = ?"
  c.username = ""
  c.userpass = ""
  exec(db, query, c.req.cookies["sid"])

proc checkLoggedIn(c: TForumData) =
  if not c.req.cookies.hasKey("sid"): return
  let sid = c.req.cookies["sid"]
  if execAffectedRows(db,
       sql("update session set lastModified = DATETIME('now') " &
           "where key = ?"),
           sid) > 0:
    c.userid = getValue(db,
      sql"select userid from session where key = ?",
      sid)

    let row = getRow(db,
      sql"select name, email, status from person where id = ?", c.userid)
    c.username = row[0]
    c.email = row[1]
    c.rank = parseEnum[Rank](row[2])

    # In order to handle the "last visit" line appropriately, i.e.
    # it shouldn't disappear after a refresh, we need to manage a
    # special field called `previousVisitAt` appropriately.
    # That is if a user hasn't been seen for more than an hour (or so), we can
    # update `previousVisitAt` to the last time they were online.
    let personRow = getRow(
      db,
      sql"""
        select strftime('%s', lastOnline), strftime('%s', previousVisitAt)
        from person where id = ?
      """,
      c.userid
    )
    c.previousVisitAt = personRow[1].parseInt
    let diff = getTime() - fromUnix(personRow[0].parseInt)
    if diff.inMinutes > 30:
      c.previousVisitAt = personRow[0].parseInt
      db.exec(
        sql"""
          update person set
            previousVisitAt = lastOnline, lastOnline = DATETIME('now')
          where id = ?;
        """,
        c.userid
      )
    else:
      db.exec(sql"update person set lastOnline = DATETIME('now') where id = ?",
              c.userid)

  else:
    #warn("SID not found in sessions. Assuming logged out.")
    discard

proc incrementViews(threadId: int) =
  const query = sql"update thread set views = views + 1 where id = ?"
  exec(db, query, threadId)

proc validateMarkdown(c: TForumData, content: string): bool =
  result = true
  try:
    discard markdownToHtml(content)
  except MarkdownError:
    result = false

proc crud(c: TCrud, table: string, data: varargs[string]): SqlQuery =
  case c
  of crCreate:
    var fields = "insert into " & table & "("
    var vals = ""
    for i, d in data:
      if i > 0:
        fields.add(", ")
        vals.add(", ")
      fields.add(d)
      vals.add('?')
    result = sql(fields & ") values (" & vals & ")")
  of crRead:
    var res = "select "
    for i, d in data:
      if i > 0: res.add(", ")
      res.add(d)
    result = sql(res & " from " & table)
  of crUpdate:
    var res = "update " & table & " set "
    for i, d in data:
      if i > 0: res.add(", ")
      res.add(d)
      res.add(" = ?")
    result = sql(res & " where id = ?")
  of crDelete:
    result = sql("delete from " & table & " where id = ?")

proc rateLimitCheck(c: TForumData): bool =
  const query40 =
    sql("SELECT count(*) FROM post where author = ? and " &
        "(strftime('%s', 'now') - strftime('%s', creation)) < 40")
  const query90 =
    sql("SELECT count(*) FROM post where author = ? and " &
        "(strftime('%s', 'now') - strftime('%s', creation)) < 90")
  const query300 =
    sql("SELECT count(*) FROM post where author = ? and " &
        "(strftime('%s', 'now') - strftime('%s', creation)) < 300")
  # TODO Why can't I pass the secs as a param?
  let last40s = getValue(db, query40, c.userId).parseInt
  let last90s = getValue(db, query90, c.userId).parseInt
  let last300s = getValue(db, query300, c.userId).parseInt
  if last40s > 1: return true
  if last90s > 2: return true
  if last300s > 6: return true
  return false


proc verifyIdentHash(
  c: TForumData, name: string, epoch: int64, ident: string
) =
  const query =
    sql"select password, salt from person where name = ?"
  var row = getRow(db, query, name)
  if row[0] == "":
    raise newForumError("User doesn't exist.", @["nick"])
  let newIdent = makeIdentHash(name, row[0], epoch, row[1])
  # Check that it hasn't expired.
  let diff = getTime() - epoch.fromUnix()
  if diff.inHours > 2:
    raise newForumError("Link expired")
  if newIdent != ident:
    raise newForumError("Invalid ident hash")

proc initialise() =
  randomize()

  config = loadConfig()
  if len(config.recaptchaSecretKey) > 0 and len(config.recaptchaSiteKey) > 0:
    captcha = initReCaptcha(config.recaptchaSecretKey, config.recaptchaSiteKey, Hcaptcha)
  else:
    doAssert config.isDev, "Recaptcha required for production!"
    warn("No recaptcha secret key specified.")

  mailer = newMailer(config)

  db = open(connection=config.dbPath, user="", password="",
              database="nimforum")
  isFTSAvailable = db.getAllRows(sql("SELECT name FROM sqlite_master WHERE " &
      "type='table' AND name='post_fts'")).len == 1

  buildCSS(config)

  # Read karax.html and set its properties.
  karaxHtml = readFile("public/karax.html") %
    {
      "title": config.title,
      "timestamp": encodeUrl(CompileDate & CompileTime),
      "ga": config.ga
    }.newStringTable()


template createTFD() =
  var c {.inject.}: TForumData
  new(c)
  init(c)
  c.req = request
  if cookies(request).len > 0:
    checkLoggedIn(c)

#[ DB functions. TODO: Move to another module? ]#

proc selectUser(userRow: seq[string], avatarSize: int=80): User =
  result = User(
    id: userRow[0],
    name: userRow[1],
    avatarUrl: userRow[2].getGravatarUrl(avatarSize),
    lastOnline: userRow[3].parseInt,
    previousVisitAt: userRow[4].parseInt,
    rank: parseEnum[Rank](userRow[5]),
    isDeleted: userRow[6] == "1"
  )

  # Don't give data about a deleted user.
  if result.isDeleted:
    result.name = "DeletedUser"
    result.avatarUrl = getGravatarUrl(result.name & userRow[2], avatarSize)

proc selectPost(postRow: seq[string], skippedPosts: seq[int],
                replyingTo: Option[PostLink], history: seq[PostInfo],
                likes: seq[User]): Post =
  let content =
    try:
      postRow[1].markdownToHtml()
    except MarkdownError:
      span(class="text-error", "Couldn't render post #$1." % postRow[0])

  return Post(
    id: postRow[0].parseInt,
    isDeleted: postRow[4] == "1",
    replyingTo: replyingTo,
    position: postRow[6].parseInt,
    author: selectUser(postRow[7..13]),
    likes: likes,
    seen: false, # TODO:
    history: history,
    info: PostInfo(
      creation: postRow[2].parseInt,
      content: content
    ),
    moreBefore: skippedPosts
  )

proc selectReplyingTo(replyingTo: string): Option[PostLink] =
  if replyingTo.len == 0: return

  const replyingToQuery = sql"""
    select p.id, strftime('%s', p.creation), p.thread, p.position,
           u.id, u.name, u.email, strftime('%s', u.lastOnline),
           strftime('%s', u.previousVisitAt), u.status,
           u.isDeleted,
           t.name
    from post p, person u, thread t
    where p.thread = t.id and p.author = u.id and p.id = ? and p.isDeleted = 0;
  """

  let row = getRow(db, replyingToQuery, replyingTo)
  if row[0].len == 0: return

  return some(PostLink(
    creation: row[1].parseInt(),
    topic: row[^1],
    threadId: row[2].parseInt(),
    postId: row[0].parseInt(),
    author: some(selectUser(row[4..10])),
    postPosition: row[3].parseInt()
  ))

proc selectHistory(postId: int): seq[PostInfo] =
  const historyQuery = sql"""
    select strftime('%s', creation), content from postRevision
    where original = ?
    order by creation asc;
  """

  result = @[]
  for row in getAllRows(db, historyQuery, $postId):
    result.add(PostInfo(
      creation: row[0].parseInt(),
      content:
        try:
          row[1].markdownToHtml()
        except MarkdownError:
          span(class="text-error", "Couldn't render historic post in #$1." % $postId)
    ))

proc selectLikes(postId: int): seq[User] =
  const likeQuery = sql"""
    select u.id, u.name, u.email, strftime('%s', u.lastOnline),
           strftime('%s', u.previousVisitAt), u.status,
           u.isDeleted
    from like h, person u
    where h.post = ? and h.author = u.id
    order by h.creation asc;
  """

  result = @[]
  for row in getAllRows(db, likeQuery, $postId):
    result.add(selectUser(row))

proc selectThreadAuthor(threadId: int): User =
  const authorQuery =
    sql"""
      select id, name, email, strftime('%s', lastOnline),
             strftime('%s', previousVisitAt), status, isDeleted
      from person where id in (
        select author from post
        where thread = ?
        order by id
        limit 1
      )
    """

  return selectUser(getRow(db, authorQuery, threadId))

proc selectThread(threadRow: seq[string], author: User): Thread =
  const postsQuery =
    sql"""select position, strftime('%s', creation) from post
          where thread = ? order by position desc limit 1;"""
  const usersListQuery =
    sql"""
      select distinct u.id, name, email, strftime('%s', lastOnline),
             strftime('%s', previousVisitAt), status, u.isDeleted
      from person u, post p where p.author = u.id and p.thread = ?
      order by p.position desc limit 5;
    """

  let posts = getRow(db, postsQuery, threadRow[0])

  var thread = Thread(
    id: threadRow[0].parseInt,
    topic: threadRow[1],
    category: Category(
      id: threadRow[7].parseInt,
      name: threadRow[8],
      description: threadRow[9],
      color: threadRow[10]
    ),
    users: @[],
    replies: posts[0].parseInt,
    views: threadRow[2].parseInt,
    activity: threadRow[3].parseInt,
    creation: posts[1].parseInt,
    isLocked: threadRow[4] == "1",
    isSolved: false, # TODO: Add a field to `post` to identify the solution.
    isPinned: threadRow[5] == "1",
    lastPost: threadRow[6].parseInt,
  )

  # Gather the users list.
  for user in getAllRows(db, usersListQuery, thread.id):
    thread.users.add(selectUser(user))

  # Grab the author.
  thread.author = author

  return thread

proc executeReply(c: TForumData, threadId: int, content: string,
                  replyingTo: Option[int]): int64 =
  # TODO: Refactor TForumData.
  assert c.loggedIn()

  if not canPost(c.rank):
    case c.rank
    of EmailUnconfirmed:
      raise newForumError("You need to confirm your email before you can post")
    else:
      raise newForumError("You are not allowed to post")

  when not defined(skipRateLimitCheck):
    if rateLimitCheck(c):
      raise newForumError("You're posting too fast!")

  if content.strip().len == 0:
    raise newForumError("Message cannot be empty")
    
  if content.strip().len > 10000:
    raise newForumError("Message is too long")

  if not validateMarkdown(c, content):
    raise newForumError("Message needs to be valid Markdown", @["msg"])

  # Ensure that the thread isn't locked.
  let isLocked = getValue(
    db,
    sql"""
      select isLocked from thread where id = ?;
    """,
    threadId
  )
  if isLocked.len == 0:
    raise newForumError("Thread not found.")

  if isLocked == "1":
    raise newForumError("Cannot reply to a locked thread.")

  var retID: int64

  let nextpos = getValue(
    db,
    sql"""
      select coalesce(max(position)+1,0) from post where thread = ?;
    """,
    threadId
  )

  if replyingTo.isSome():
    retID = insertID(
      db,
      crud(crCreate, "post", "author", "ip", "content", "thread", "replyingTo", "position"),
      c.userId, c.req.ip, content, $threadId, $replyingTo.get(), nextpos
    )
  else:
    retID = insertID(
      db,
      crud(crCreate, "post", "author", "ip", "content", "thread", "position"),
      c.userId, c.req.ip, content, $threadId, nextpos
    )

  discard tryExec(
    db,
    crud(crCreate, "post_fts", "id", "content"),
    retID.int, content
  )

  exec(db, sql"update thread set modified = DATETIME('now') where id = ?",
       $threadId)
  exec(db, sql"update thread set lastpost = ? where id = ?",
       $retID, $threadId)
  exec(db, sql"update person set posts = posts + 1 where id = ?",
       c.userId)

  return retID

proc updatePost(c: TForumData, postId: int, content: string,
                subject: Option[string]) =
  ## Updates an existing post.
  assert c.loggedIn()

  let postQuery = sql"""
    select author, strftime('%s', creation), thread
    from post where id = ?
  """

  let postRow = getRow(db, postQuery, postId)

  # Verify that the current user has permissions to edit the specified post.
  let creation = fromUnix(postRow[1].parseInt)
  let isArchived = (getTime() - creation).inHours >= 2
  let canEdit = c.rank == Admin or c.userid == postRow[0]
  if isArchived and c.rank < Admin:
    raise newForumError("This post is too old and can no longer be edited")
  if not canEdit:
    raise newForumError("You cannot edit this post")

  if not validateMarkdown(c, content):
    raise newForumError("Message needs to be valid Markdown", @["msg"])

  if content.strip().len > 10000:
    raise newForumError("Message is too long")

  # Update post.
  # - We create a new postRevision entry for our edit.
  exec(
    db,
    crud(crCreate, "postRevision", "content", "original"),
    content,
    $postId
  )
  # - We set the FTS to the latest content as searching for past edits is not
  #   supported.
  exec(db, crud(crUpdate, "post_fts", "content"), content, $postId)
  # Check if post is the first post of the thread.
  if subject.isSome():
    let threadId = postRow[2]
    let row = db.getRow(sql("""
        select id from post where thread = ? order by id asc
      """), threadId)
    if row[0] == $postId:
      exec(db, crud(crUpdate, "thread", "name"), subject.get(), threadId)

proc updateThread(c: TForumData, threadId: string, queryKeys: seq[string], queryValues: seq[string]) =
  let threadAuthor = selectThreadAuthor(threadId.parseInt)

  # Verify that the current user has permissions to edit the specified thread.
  #change permission
  #let canEdit = c.rank in {Admin, Moderator} or c.userid == threadAuthor.id
  let canEdit = c.rank in {Admin, Moderator}
  if not canEdit:
    raise newForumError("You cannot edit this thread")

  exec(db, crud(crUpdate, "thread", queryKeys), queryValues)

proc executeNewThread(c: TForumData, subject, msg, categoryID: string): (int64, int64) =
  const
    query = sql"""
      insert into thread(name, views, modified, category, lastPost) values (?, 0, DATETIME('now'), ?, 0)
    """

  assert c.loggedIn()

  if not canPost(c.rank):
    case c.rank
    of EmailUnconfirmed:
      raise newForumError("You need to confirm your email before you can post")
    else:
      raise newForumError("You are not allowed to post")

  if subject.len <= 2:
    raise newForumError("Subject is too short", @["subject"])
  if subject.len > 100:
    raise newForumError("Subject is too long", @["subject"])

  if msg.len == 0:
    raise newForumError("Message is empty", @["msg"])

  let catID = getInt(categoryID, -1)
  if catID == -1:
    raise newForumError("CategoryID is invalid", @["categoryId"])

  if not validateMarkdown(c, msg):
    raise newForumError("Message needs to be valid Markdown", @["msg"])

  when not defined(skipRateLimitCheck):
    if rateLimitCheck(c):
      raise newForumError("You're posting too fast!")

  result[0] = tryInsertID(db, query, subject, categoryID).int
  if result[0] < 0:
    raise newForumError("Subject already exists", @["subject"])
    
  discard tryExec(db, sql"update person set threads = threads + 1 where id = ?", c.userId)
  discard tryExec(db, sql"update category set threads = threads + 1 where id = ?", catID) 

  discard tryExec(db, crud(crCreate, "thread_fts", "id", "name"),
                  result[0], subject)
  result[1] = executeReply(c, result[0].int, msg, none[int]())
  discard tryExec(db, crud(crUpdate, "thread", "lastPost"), result[1].int, result[0].int)
  #discard tryExec(db, sql"insert into post_fts(post_fts) values('optimize')")
  #discard tryExec(db, sql"insert into thread_fts(thread_fts) values('optimize')")

proc optimizeFTS() {.async.} =
  #merge all existing index b-trees
  discard tryExec(db, sql"insert into post_fts(post_fts) values('optimize')")
  discard tryExec(db, sql"insert into thread_fts(thread_fts) values('optimize')")

proc executeLogin(c: TForumData, username, password: string): string =
  ## Performs a login with the specified details.
  ##
  ## Optionally, `username` may contain the email of the user instead.
  const query =
    sql"""
      select id, name, password, email, salt
      from person where (name = ? or email = ?) and isDeleted = 0
    """

  let username = username.strip()
  if username.len == 0:
    raise newForumError("Username cannot be empty", @["username"])

  for row in fastRows(db, query, username, username):
    if row[2] == makePassword(password, row[4], row[2]) or
      row[2] == makePhpbbPassword(password, row[2]):
      let key = makeSessionKey()
      exec(
        db,
        sql"insert into session (ip, key, userid) values (?, ?, ?)",
        c.req.ip, key, row[0]
      )
      return key

  raise newForumError("Invalid username or password")

proc validateEmail(email: string, checkDuplicated: bool) =
  if not ('@' in email and '.' in email):
    raise newForumError("Invalid email", @["email"])
  if checkDuplicated:
    if getValue(
      db,
      sql"select email from person where email = ? and isDeleted = 0",
      email
    ).len > 0:
      raise newForumError("Email already exists", @["email"])

proc executeRegister(c: TForumData, name, pass, antibot, userIp,
                     email: string) {.async.} =
  ## Registers a new user.

  # email validation
  validateEmail(email, checkDuplicated=true)

  # Username validation:
  if name.len == 0 or not allCharsInSet(name, UsernameIdent) or name.len > 20:
    raise newForumError("Invalid username", @["username"])
  if getValue(
    db,
    sql"select name from person where name = ? collate nocase and isDeleted = 0",
    name
  ).len > 0:
    raise newForumError("Username already exists", @["username"])

  # Password validation:
  if pass.len < 4:
    raise newForumError("Please choose a longer password", @["password"])

  await validateCaptcha(antibot, userIp)

  # perform registration:
  var salt = makeSalt()
  let password = makePassword(pass, salt)

  # Send activation email.
  await sendSecureEmail(
    mailer, ActivateEmail, c.req, name, password, email, salt
  )

  # Add account to person table
  exec(db, sql"""
    INSERT INTO person(name, password, email, salt, status, lastOnline)
    VALUES (?, ?, ?, ?, ?, DATETIME('now'))
  """, name, password, email, salt, $Moderated)

proc executeLike(c: TForumData, postId: int) =
  # Verify the post exists and doesn't belong to the current user.
  const postQuery = sql"""
    select u.name from post p, person u
    where p.id = ? and p.author = u.id and p.isDeleted = 0;
  """

  let postAuthor = getValue(db, postQuery, postId)
  if postAuthor.len == 0:
    raise newForumError("Specified post ID does not exist.", @["id"])

  if postAuthor == c.username:
    raise newForumError("You cannot like your own post.")

  # Save the like.
  exec(db, crud(crCreate, "like", "author", "post"), c.userid, postId)

proc executeNewCategory(c: TForumData, name, color, description: string): int64 =

  let canAdd = c.rank == Admin

  if not canAdd:
    raise newForumError("You do not have permissions to add a category.")

  if name.len == 0:
    raise newForumError("Category name must not be empty!", @["name"])

  result = insertID(db, crud(crCreate, "category", "name", "color", "description"), name, color, description)

proc executeUnlike(c: TForumData, postId: int) =
  # Verify the post and like exists for the current user.
  const likeQuery = sql"""
    select l.id from like l, person u
    where l.post = ? and l.author = u.id and u.name = ?;
  """

  let likeId = getValue(db, likeQuery, postId, c.username)
  if likeId.len == 0:
    raise newForumError("Like doesn't exist.", @["id"])

  # Delete the like.
  exec(db, crud(crDelete, "like"), likeId)

proc executeLockState(c: TForumData, threadId: int, locked: bool) =
  # Verify that the logged in user has the correct permissions.
  if c.rank < Moderator:
    raise newForumError("You cannot lock this thread.")

  # Save the like.
  exec(db, crud(crUpdate, "thread", "isLocked"), locked.int, threadId)

proc executePinState(c: TForumData, threadId: int, pinned: bool) =
  if c.rank < Moderator:
    raise newForumError("You do not have permission to pin this thread.")

  # (Un)pin this thread
  exec(db, crud(crUpdate, "thread", "isPinned"), pinned.int, threadId)

proc executeDeletePost(c: TForumData, postId: int) =
  # Verify that this post belongs to the user.
  const postQuery = sql"""
    select p.author, p.id from post p
    where p.author = ? and p.id = ?
  """
  let
    row = getRow(db, postQuery, c.username, postId)
    author = row[0]
    id = row[1]

  #if id.len == 0 and not (c.rank == Admin or c.userid == author):
  #change permission
  if id.len == 0 and not (c.rank == Admin):
    raise newForumError("You cannot delete this post")

  # Set the `isDeleted` flag.
  exec(db, crud(crUpdate, "post", "isDeleted"), "1", postId)

proc executeDeleteThread(c: TForumData, threadId: int) =
  # Verify that this thread belongs to the user.
  let author = selectThreadAuthor(threadId)
  #if author.name != c.username and c.rank < Admin:
  #change permission
  if c.rank < Admin:
    raise newForumError("You cannot delete this thread")

  # Set the `isDeleted` flag.
  exec(db, crud(crUpdate, "thread", "isDeleted"), "1", threadId)
  exec(db, sql"""update category set threads = threads-1 where id in 
             (select category from thread where id = ?);""", threadId)

proc executeDeleteUser(c: TForumData, username: string) =
  # Verify that the current user has the permissions to do this.
  #if username != c.username and c.rank < Admin:
  if c.rank < Admin:
  #change permission
    raise newForumError("You cannot delete this user.")

  # Set the `isDeleted` flag.
  exec(db, sql"update person set isDeleted = 1 where name = ?;", username)

  logout(c)

proc updateProfile(
  c: TForumData, username, email: string, rank: Rank
) {.async.} =
  if c.rank < rank:
    raise newForumError("You cannot set a rank that is higher than yours.")

  if c.username != username and c.rank < Moderator:
    raise newForumError("You can't change this profile.")

  # Check if we are only setting the rank.
  if email.len == 0:
    exec(
      db,
      sql"update person set status = ? where name = ?;",
      $rank, username
    )
    return

  # Make sure the rank is set to EmailUnconfirmed when the email changes.
  let row = getRow(
    db,
    sql"select name, password, email, salt from person where name = ?",
    username
  )
  let wasEmailChanged = row[2] != email
  if c.rank < Moderator and wasEmailChanged:
    if rank != EmailUnconfirmed:
      raise newForumError("Rank needs a change when setting new email.")

    await sendSecureEmail(
      mailer, ActivateEmail, c.req, row[0], row[1], email, row[3]
    )

  validateEmail(email, checkDuplicated=wasEmailChanged)

  exec(
    db,
    sql"update person set status = ?, email = ? where name = ?;",
    $rank, email, username
  )

include "main.tmpl"

initialise()

settings:
  port = config.port.Port

routes:

  get "/categories.json":
    # TODO: Limit this query in the case of many many categories
    const categoriesQuery =
      sql"""
        select id, name, description, color, threads
        from category
        where position >= 0 and id != 7
        order by position
        limit 100;
      """

    var list = CategoryList(categories: @[])
    for data in getAllRows(db, categoriesQuery):
      let category = Category(
        id: data[0].getInt, name: data[1], description: data[2], color: data[3], numTopics: data[4].parseInt
      )
      list.categories.add(category)

    resp $(%list), "application/json"

  get "/users.json":
    const count = sql("SELECT count(*) FROM person")
    let total = getValue(db, count).parseInt
    
    var
      start = getInt(@"start", 0)
    if start > total: start = 0
    
    const usersQuery =
      sql"""
        select id, name, email, strftime('%s', lastOnline),
           strftime('%s', previousVisitAt), status, isDeleted
        from person
        order by id
        limit ?, 40;
      """

    var list = UserList(users: @[])
    for data in getAllRows(db, usersQuery, start):
      let user = selectUser(data, avatarSize=80)
      list.users.add(user)
      
    list.pages = total

    resp $(%list), "application/json"
    
    
  get "/pm.json":
    createTFD()
    if not c.loggedIn():
      let err = PostError(
        errorFields: @[],
        message: "Not logged in."
      )
      resp Http401, $(%err), "application/json"

    let count =
      if c.rank >= Admin:
        sql("SELECT count(*) FROM privmsgs")
      else:
        sql("SELECT count(*) FROM privmsgs WHERE author = ? OR recipient = ?")
    let total =
      if c.rank >= Admin:
        getValue(db, count).parseInt
      else:
        getValue(db, count, c.userId, c.userId).parseInt

    var
      start = getInt(@"start", 0)
    if start > total: start = 0
    
    let privmsgsQuery =
      if c.rank >= Admin:
        sql"""
          select pm.id, pm.author, pm.content, pm.subject, strftime('%s', pm.creation), 
             u.id, u.name, u.email, strftime('%s', u.lastOnline),
             strftime('%s', u.previousVisitAt), u.status,
             u.isDeleted, ut.name
          from privmsgs pm, person u, person ut
          where pm.author = u.id AND pm.recipient = ut.id
          order by pm.id desc
          limit ?, 20;
        """
      else:
        sql"""
          select pm.id, pm.author, pm.content, pm.subject, strftime('%s', pm.creation), 
             u.id, u.name, u.email, strftime('%s', u.lastOnline),
             strftime('%s', u.previousVisitAt), u.status,
             u.isDeleted, ut.name
          from privmsgs pm, person u, person ut
           where (pm.author = ? OR pm.recipient = ?) AND pm.author = u.id AND pm.recipient = ut.id
          order by pm.id desc
          limit ?, 20;
        """

    var list = PrivmsgList(privmsgs: @[])
    
    let rows =
      if c.rank >= Admin:
        getAllRows(db, privmsgsQuery, start)
      else:
        getAllRows(db, privmsgsQuery, c.userId, c.userId, start)
      
    for data in rows:
      list.privmsgs.add(Privmsg(
        id: data[0].parseInt(),
        author: selectUser(data[5..11], avatarSize=80),
        creation: data[4].parseInt(),
        content: data[2].markdownToHtml(),
        topic: data[3],
        recipient: data[12]
      ))
      
    list.pages = total

    resp $(%list), "application/json"

  get "/threads.json":
    var
      start = getInt(@"start", 0)
      count = getInt(@"count", 30)
      categoryId = getInt(@"categoryId", -1)
    if count > 30: count = 30

    var
      categorySection = ""
      categoryPinned = ""
      categoryArgs: seq[string] = @[$start, $count]
      countQuery = sql"select sum(threads) from category;"
      countArgs: seq[string] = @[]

    if categoryId != -1:
      categorySection = "c.id == ? and "
      categoryPinned = "isPinned desc,"
      countQuery = sql"select threads from category where id == ?;"
      countArgs.add($categoryId)
      categoryArgs.insert($categoryId, 0)
    
    const threadsQuery =
      """select t.id, t.name, views, strftime('%s', modified), isLocked, isPinned, lastPost,
                   c.id, c.name, c.description, c.color,
                   u.id, u.name, u.email, strftime('%s', u.lastOnline),
                   strftime('%s', u.previousVisitAt), u.status, u.isDeleted
            from thread t, category c, person u
            where t.isDeleted = 0 and category = c.id and $#
                  u.status <> 'Spammer' and u.status <> 'Troll' and
                  u.id = (
                    select p.author from post p
                    where p.thread = t.id
                    order by p.position
                    limit 1
                  )
            order by $# modified desc limit ?, ?;"""

    let thrCount = getValue(db, countQuery, countArgs).parseInt()
    let moreCount = max(0, thrCount - (start + count))

    var list = ThreadList(threads: @[], moreCount: moreCount)
    for data in getAllRows(db, sql(threadsQuery % [categorySection, categoryPinned] ), categoryArgs):
      let thread = selectThread(data[0 .. 10], selectUser(data[11 .. ^1]))
      list.threads.add(thread)

    resp $(%list), "application/json"

  get "/posts.json":
    createTFD()
    var
      id = getInt(@"id", -1)
      anchor = getInt(@"anchor", -1)
      start = getInt(@"start", 0)
    cond id != -1
    const
      count = 100

    const threadsQuery =
      sql"""select t.id, t.name, views, strftime('%s', modified), isLocked, isPinned, lastPost,
                   c.id, c.name, c.description, c.color
            from thread t, category c
            where t.id = ? and isDeleted = 0 and category = c.id;"""

    let threadRow = getRow(db, threadsQuery, id)
    if threadRow[0].len == 0:
      let err = PostError(
        message: "Specified thread does not exist"
      )
      resp Http404, $(%err), "application/json"
    let thread = selectThread(threadRow, selectThreadAuthor(id))
    
    if start > thread.replies: start = 0

    let postsQuery =
      sql(
        """select p.id, p.content, strftime('%s', p.creation), p.author,
                  p.isDeleted, p.replyingTo, p.position,
                  u.id, u.name, u.email, strftime('%s', u.lastOnline),
                  strftime('%s', u.previousVisitAt), u.status,
                  u.isDeleted
           from post p, person u
           where u.id = p.author and p.thread = ? and position between ? and ?
           order by p.position"""
      )

    var list = PostList(
      posts: @[],
      history: @[],
      thread: thread
    )
    let rows = getAllRows(db, postsQuery, id, start, start+postPerPage()-1)

    var skippedPosts: seq[int] = @[]
    for i in 0 ..< rows.len:
      let id = rows[i][0].parseInt

      let addDetail = i < count or rows.len-i < count or id == anchor

      if addDetail:
        let replyingTo = selectReplyingTo(rows[i][5])
        let history = selectHistory(id)
        let likes = selectLikes(id)
        let post = selectPost(
          rows[i], skippedPosts, replyingTo, history, likes
        )
        list.posts.add(post)
        skippedPosts = @[]
      else:
        skippedPosts.add(id)

    incrementViews(id)

    resp $(%list), "application/json"

  get "/specific_posts.json":
    createTFD()
    var ids: JsonNode
    try:
      ids = parseJson(@"ids")
    except JsonParsingError:
      let err = PostError(
        message: "Invalid JSON in the `ids` parameter"
      )
      resp Http400, $(%err), "application/json"
    cond ids.kind == JArray
    let intIDs = ids.elems.map(x => x.getInt())
    assert intIDs.len <= 100
    let postsQuery = sql("""
      select p.id, p.content, strftime('%s', p.creation), p.author,
             p.isDeleted, p.replyingTo, p.position,
             u.id, u.name, u.email, strftime('%s', u.lastOnline),
             strftime('%s', u.previousVisitAt), u.status,
             u.isDeleted
      from post p, person u
      where u.id = p.author and p.id in ($#)
      order by p.id limit 100;
    """ % intIDs.join(",")) # TODO: It's horrible that I have to do this.

    var list: seq[Post] = @[]

    for row in db.getAllRows(postsQuery):
      let history = selectHistory(row[0].parseInt())
      let likes = selectLikes(row[0].parseInt())
      list.add(selectPost(row, @[], selectReplyingTo(row[5]), history, likes))

    resp $(%list), "application/json"

  get "/unread/@id":
    cond "id" in request.params
    createTFD()
    const postsNewQuery =
      sql"""select p.id, p.position from person u, post p
          where p.thread = ? and u.id = ? and
          p.creation > u.previousVisitAt order by p.creation limit 1;"""
    let postsNew = getRow(db, postsNewQuery, @"id", c.userid)
    var read, firstUnread = 0
    if postsNew[0].len != 0:
      read = postsNew[1].parseInt
      firstUnread = postsNew[0].parseInt
      var page = (read div postPerPage())*postPerPage()
      var threadId = @"id"
      if page > 0:
        redirect uri(fmt"/t/{threadId}/s/{page}#{firstUnread}")
      else:
        redirect uri(fmt"/t/{threadId}#{firstUnread}")
    else:
      redirect uri("/t/" & @"id")

  get "/post.md":
    createTFD()
    let postId = getInt(@"id", -1)
    cond postId != -1

    let postQuery = sql"""
      select content from (
        select content, creation from post where id = ?
        union
        select content, creation from postRevision where original = ?
      )
      order by creation desc limit 1;
    """

    let content = getValue(db, postQuery, postId, postId)
    if content.len == 0:
      resp Http404, "Post not found"
    else:
      resp content, "text/markdown"

  get "/profile.json":
    createTFD()
    var
      username = @"username"

    let threadsFrom = """
      from thread t, post p
      where p.thread = t.id and p.position = 0 and p.author = ?
    """

    let postsFrom = """
      from post p,thread t
      where p.thread = t.id and p.author = ?
    """

    let postsQuery = sql("""
      select p.id, strftime('%s', p.creation), p.position,
             t.name, t.id
      $1
      order by p.id desc limit 10;
    """ % postsFrom)

    let userQuery = sql("""
      select id, name, email, strftime('%s', lastOnline),
             strftime('%s', previousVisitAt), status, isDeleted,
             strftime('%s', creation), id, posts, threads
      from person
      where name = ? and isDeleted = 0
    """)

    var profile = Profile(
      threads: @[],
      posts: @[]
    )

    let userRow = db.getRow(userQuery, username)

    let userID = userRow[^3]
    if userID.len == 0:
      halt()

    profile.user = selectUser(userRow, avatarSize=200)
    profile.joinTime = userRow[^4].parseInt()
    profile.postCount = userRow[^2].parseInt()
    profile.threadCount = userRow[^1].parseInt()

    if c.rank >= Admin or c.username == username:
      profile.email = some(userRow[2])

    for row in db.getAllRows(postsQuery, userID):
      profile.posts.add(
        PostLink(
          creation: row[1].parseInt(),
          topic: row[3],
          threadId: row[4].parseInt(),
          postId: row[0].parseInt(),
          postPosition: row[2].parseInt()
        )
      )

    let threadsQuery = sql("""
      select t.id, t.name, strftime('%s', p.creation), p.id
      $1
      order by p.id
      desc limit 10;
    """ % threadsFrom)

    for row in db.getAllRows(threadsQuery, userID):
      profile.threads.add(
        PostLink(
          creation: row[2].parseInt(),
          topic: row[1],
          threadId: row[0].parseInt(),
          postId: row[3].parseInt(),
          postPosition: 0
        )
      )

    resp $(%profile), "application/json"

  post "/login":
    createTFD()
    let formData = request.formData
    cond "username" in formData
    cond "password" in formData
    try:
      let session = executeLogin(
        c,
        formData["username"].body,
        formData["password"].body
      )
      setCookie("sid", session, httpOnly=true, sameSite=Strict, secure=false)
      resp Http200, "{}", "application/json"
    except ForumError as exc:
      resp Http400, $(%exc.data), "application/json"

  post "/signup":
    createTFD()
    let formData = request.formData
    if not config.isDev:
      cond "g-recaptcha-response" in formData

    let username = formData["username"].body
    let password = formData["password"].body
    let recaptcha =
      if "g-recaptcha-response" in formData:
        formData["g-recaptcha-response"].body
      else:
        ""
    try:
      await executeRegister(
        c,
        username,
        password,
        recaptcha,
        request.host,
        formData["email"].body
      )
      let session = executeLogin(c, username, password)
      setCookie("sid", session, httpOnly=true, sameSite=Strict, secure=false)
      resp Http200, "{}", "application/json"
    except ForumError as exc:
      resp Http400, $(%exc.data), "application/json"

  post "/createCategory":
    createTFD()
    let formData = request.formData

    let name = formData["name"].body
    let color = formData["color"].body.replace("#", "")
    let description = formData["description"].body

    try:
      let id = executeNewCategory(c, name, color, description)
      let category = Category(id: id.int, name: name, color: color, description: description)
      resp Http200, $(%category), "application/json"
    except ForumError as exc:
      resp Http400, $(%exc.data), "application/json"

  get "/status.json":
    createTFD()

    let user =
      if @"logout" == "true":
        logout(c); none[User]()
      elif c.loggedIn():
        some(User(
          name: c.username,
          avatarUrl: c.email.getGravatarUrl(),
          lastOnline: getTime().toUnix(),
          previousVisitAt: c.previousVisitAt,
          rank: c.rank
        ))
      else:
        none[User]()

    let status = UserStatus(
      user: user,
      recaptchaSiteKey:
        if not config.isDev:
          some(config.recaptchaSiteKey)
        else:
          none[string]()
    )
    resp $(%status), "application/json"

  post "/preview":
    createTFD()
    if not c.loggedIn():
      let err = PostError(
        errorFields: @[],
        message: "Not logged in."
      )
      resp Http401, $(%err), "application/json"

    let formData = request.formData
    cond "msg" in formData

    let msg = formData["msg"].body
    
    if msg.strip().len > 10000:
      let err = PostError(
        errorFields: @[],
        message: "Message is too long."
      )
      resp Http401, $(%err), "application/json"
    
    try:
      let rendered = msg.markdownToHtml()
      resp Http200, rendered
    except MarkdownError:
      let err = PostError(
        errorFields: @[],
        message: "Message needs to be valid Markdown! Error: " &
                 getCurrentExceptionMsg()
      )
      resp Http400, $(%err), "application/json"

  post "/createPost":
    createTFD()
    if not c.loggedIn():
      let err = PostError(
        errorFields: @[],
        message: "Not logged in."
      )
      resp Http401, $(%err), "application/json"

    let formData = request.formData
    cond "msg" in formData
    cond "threadId" in formData

    let msg = formData["msg"].body
    let threadId = getInt(formData["threadId"].body, -1)
    cond threadId != -1

    let replyingToId =
      if "replyingTo" in formData:
        getInt(formData["replyingTo"].body, -1)
      else:
        -1
    let replyingTo =
      if replyingToId == -1: none[int]()
      else: some(replyingToId)

    try:
      let id = executeReply(c, threadId, msg, replyingTo)
      resp Http200, $(%id), "application/json"
    except ForumError as exc:
      resp Http400, $(%exc.data), "application/json"

  post "/updatePost":
    createTFD()
    if not c.loggedIn():
      let err = PostError(
        errorFields: @[],
        message: "Not logged in."
      )
      resp Http401, $(%err), "application/json"

    let formData = request.formData
    cond "msg" in formData
    cond "postId" in formData

    let msg = formData["msg"].body
    let postId = getInt(formData["postId"].body, -1)
    cond postId != -1
    let subject =
      if "subject" in formData:
        some(formData["subject"].body)
      else:
        none[string]()

    try:
      updatePost(c, postId, msg, subject)
      resp Http200, msg.markdownToHtml(), "text/html"
    except ForumError as exc:
      resp Http400, $(%exc.data), "application/json"

  post "/updateThread":
    # TODO: Add some way of keeping track of modifications for historical
    # purposes
    createTFD()
    if not c.loggedIn():
      let err = PostError(
        errorFields: @[],
        message: "Not logged in."
      )
      resp Http401, $(%err), "application/json"

    let formData = request.formData

    cond "threadId" in formData

    let threadId = formData["threadId"].body

    # TODO: might want to add more properties here under a tighter permissions
    # model
    let keys = ["name", "category", "solution"]

    # optional parameters
    var
      queryValues: seq[string] = @[]
      queryKeys: seq[string] = @[]

    for key in keys:
      if key in formData:
        queryKeys.add(key)
        queryValues.add(formData[key].body)

    if queryKeys.len() > 0:
      queryValues.add(threadId)
      try:
        updateThread(c, threadId, queryKeys, queryValues)
        resp Http200, "{}", "application/json"
      except ForumError as exc:
        resp Http400, $(%exc.data), "application/json"

  post "/newthread":
    createTFD()
    if not c.loggedIn():
      let err = PostError(
        errorFields: @[],
        message: "Not logged in."
      )
      resp Http401, $(%err), "application/json"

    let formData = request.formData
    cond "msg" in formData
    cond "subject" in formData
    cond "categoryId" in formData

    let msg = formData["msg"].body
    let subject = formData["subject"].body
    let categoryID = formData["categoryId"].body

    try:
      let res = executeNewThread(c, subject, msg, categoryID)
      resp Http200, $(%[res[0], res[1]]), "application/json"
      await optimizeFTS()
    except ForumError as exc:
      resp Http400, $(%exc.data), "application/json"

  post "/newpm":
    createTFD()
    if not c.loggedIn():
      let err = PostError(
        errorFields: @[],
        message: "Not logged in."
      )
      resp Http401, $(%err), "application/json"

    let formData = request.formData
    cond "msg" in formData
    cond "subject" in formData
    cond "recipient" in formData

    let msg = formData["msg"].body
    let subject = formData["subject"].body
    let recipient = formData["recipient"].body

    try:
      const
        query = sql"""
          insert into privmsgs(author, ip, content, subject, creation, recipient)  values (?, ?, ?, ?, DATETIME('now'), ?)
          """

      assert c.loggedIn()

      if not canPost(c.rank):
        case c.rank
        of EmailUnconfirmed:
          raise newForumError("You need to confirm your email before you can post")
        else:
          raise newForumError("You are not allowed to post")

      if subject.len <= 2:
        raise newForumError("Subject is too short", @["subject"])
      if subject.len > 100:
        raise newForumError("Subject is too long", @["subject"])
        
      let userid = getValue(
        db,
        sql"select id from person where name = ? collate nocase and isDeleted = 0",
        recipient)
      
      if userid.len == 0:
        raise newForumError("Username not exists", @["recipient"])

      if msg.len == 0:
        raise newForumError("Message is empty", @["msg"])
      if msg.len > 4096:
        raise newForumError("Message is too long", @["msg"])

      const query3600 =
        sql("SELECT count(*) FROM privmsgs where author = ? and " &
        "(strftime('%s', 'now') - strftime('%s', creation)) < 3600 limit 15")
      let last3600s = getValue(db, query3600, c.userId).parseInt
      if last3600s > 10:
        raise newForumError("You're posting too fast!", @["msg"])

      if not validateMarkdown(c, msg):
        raise newForumError("Message needs to be valid Markdown", @["msg"])

      let res = tryInsertID(db, query, c.userId, c.req.ip, msg, subject, userid).int
      if res < 0:
        raise newForumError("Subject already exists", @["subject"])

      resp Http200, $(%[res]), "application/json"
    except ForumError as exc:
      resp Http400, $(%exc.data), "application/json"

  post re"/(like|unlike)":
    createTFD()
    if not c.loggedIn():
      let err = PostError(
        errorFields: @[],
        message: "Not logged in."
      )
      resp Http401, $(%err), "application/json"

    let formData = request.formData
    cond "id" in formData

    let postId = getInt(formData["id"].body, -1)
    cond postId != -1

    try:
      case request.path
      of "/like":
        executeLike(c, postId)
      of "/unlike":
        executeUnlike(c, postId)
      else:
        assert false
      resp Http200, "{}", "application/json"
    except ForumError as exc:
      resp Http400, $(%exc.data), "application/json"

  post re"/(lock|unlock)":
    createTFD()
    if not c.loggedIn():
      let err = PostError(
        errorFields: @[],
        message: "Not logged in."
      )
      resp Http401, $(%err), "application/json"

    let formData = request.formData
    cond "id" in formData

    let threadId = getInt(formData["id"].body, -1)
    cond threadId != -1

    try:
      case request.path
      of "/lock":
        executeLockState(c, threadId, true)
      of "/unlock":
        executeLockState(c, threadId, false)
      else:
        assert false
      resp Http200, "{}", "application/json"
    except ForumError as exc:
      resp Http400, $(%exc.data), "application/json"

  post re"/(pin|unpin)":
    createTFD()
    if not c.loggedIn():
      let err = PostError(
        errorFields: @[],
        message: "Not logged in."
      )
      resp Http401, $(%err), "application/json"

    let formData = request.formData
    cond "id" in formData

    let threadId = getInt(formData["id"].body, -1)
    cond threadId != -1

    try:
      case request.path
      of "/pin":
        executePinState(c, threadId, true)
      of "/unpin":
        executePinState(c, threadId, false)
      else:
        assert false
      resp Http200, "{}", "application/json"
    except ForumError as exc:
      resp Http400, $(%exc.data), "application/json"

  post re"/delete(Post|Thread)":
    createTFD()
    if not c.loggedIn():
      let err = PostError(
        errorFields: @[],
        message: "Not logged in."
      )
      resp Http401, $(%err), "application/json"

    let formData = request.formData
    cond "id" in formData

    let id = getInt(formData["id"].body, -1)
    cond id != -1

    try:
      case request.path
      of "/deletePost":
        executeDeletePost(c, id)
      of "/deleteThread":
        executeDeleteThread(c, id)
      else:
        assert false
      resp Http200, "{}", "application/json"
    except ForumError as exc:
      resp Http400, $(%exc.data), "application/json"

  post "/deleteUser":
    createTFD()
    if not c.loggedIn():
      let err = PostError(
        errorFields: @[],
        message: "Not logged in."
      )
      resp Http401, $(%err), "application/json"

    let formData = request.formData
    cond "username" in formData

    let username = formData["username"].body

    try:
      executeDeleteUser(c, username)
      resp Http200, "{}", "application/json"
    except ForumError as exc:
      resp Http400, $(%exc.data), "application/json"

  post "/saveProfile":
    createTFD()
    if not c.loggedIn():
      let err = PostError(
        errorFields: @[],
        message: "Not logged in."
      )
      resp Http401, $(%err), "application/json"

    let formData = request.formData
    cond "username" in formData
    cond "email" in formData
    cond "rank" in formData

    let username = formData["username"].body
    let email = formData["email"].body
    let rank = parseEnum[Rank](formData["rank"].body)

    try:
      await updateProfile(c, username, email, rank)
      resp Http200, "{}", "application/json"
    except ForumError as exc:
      resp Http400, $(%exc.data), "application/json"

  post "/sendResetPassword":
    createTFD()

    let formData = request.formData
    let recaptcha =
      if "g-recaptcha-response" in formData:
        formData["g-recaptcha-response"].body
      else:
        ""

    if not c.loggedIn():
      if not config.isDev:
        if "g-recaptcha-response" notin formData:
          let err = PostError(
            errorFields: @[],
            message: "Not logged in and no recaptcha."
          )
          resp Http401, $(%err), "application/json"

    cond "email" in formData
    try:
      await sendResetPassword(
        c, formData["email"].body, recaptcha, request.host
      )
      resp Http200, "{}", "application/json"
    except ForumError as exc:
      resp Http400, $(%exc.data), "application/json"

  post "/resetPassword":
    createTFD()
    cond(@"nick" != "")
    cond(@"epoch" != "")
    cond(@"ident" != "")
    cond(@"newPassword" != "")
    let epoch = getInt64(@"epoch", -1)
    try:
      verifyIdentHash(c, @"nick", epoch, @"ident")
      var salt = makeSalt()
      let password = makePassword(@"newPassword", salt)

      exec(
        db,
        sql"""
          update person set password = ?, salt = ?,
                            lastOnline = DATETIME('now')
          where name = ?;
        """,
        password, salt, @"nick"
      )

      # Remove all sessions.
      exec(
        db,
        sql"""
          delete from session where userid = (
            select id from person
            where name = ?
          )
        """,
        @"nick"
      )
      resp Http200, "{}", "application/json"
    except ForumError as exc:
      resp Http400, $(%exc.data), "application/json"

  post "/activateEmail":
    createTFD()
    cond(@"nick" != "")
    cond(@"epoch" != "")
    cond(@"ident" != "")
    let epoch = getInt64(@"epoch", -1)
    try:
      verifyIdentHash(c, @"nick", epoch, @"ident")

      exec(
        db,
        sql"""
          update person set status = ?, lastOnline = DATETIME('now')
          where name = ?;
        """,
        $Rank.Moderated, @"nick"
      )
      resp Http200, "{}", "application/json"
    except ForumError as exc:
      resp Http400, $(%exc.data), "application/json"

  get "/t/@id":
    cond "id" in request.params

    const threadsQuery =
      sql"""select id from thread where id = ? and isDeleted = 0;"""

    let value = getValue(db, threadsQuery, @"id")
    if value == @"id":
      pass
    else:
      redirect uri("/404")

  get "/t/@id/@page":
    redirect uri("/t/" & @"id")

  get "/profile/@username":
    cond "username" in request.params

    let username = decodeUrl(@"username")
    const threadsQuery =
      sql"""select name from person where name = ? and isDeleted = 0;"""

    let value = getValue(db, threadsQuery, username)
    if value == username:
      pass
    else:
      redirect uri("/404")

  get "/404":
    resp Http404, readFile("public/karax.html")

  get "/about/license.html":
    let content = readFile("public/license.rst") %
      {
        "hostname": config.hostname,
        "name": config.name
      }.newStringTable()
    resp content.rstToHtml()

  get "/about/rst.html":
    let content = readFile("public/rst.rst")
    resp content.rstToHtml()
    
  get "/about/codeofconduct.html":
    let content = readFile("public/codeofconduct.rst") %
      {
        "name": config.name
      }.newStringTable()
    resp content.rstToHtml()

  get "/threadActivity.xml":
    createTFD()
    resp genThreadsRSS(c), "application/atom+xml"

  get "/postActivity.xml":
    createTFD()
    resp genPostsRSS(c), "application/atom+xml"

  get "/search.json":
    cond "q" in request.params
    let q = @"q".replace(")", "").replace("(", "")
    cond q.len > 0

    var results: seq[SearchResult] = @[]

    const queryFT = "fts.sql".slurp.sql
    const count = 30
    let data = [
      q, q, $count, $0, q,
      q, $count, $0, q
    ]
    for rowFT in fastRows(db, queryFT, data):
      var content = rowFT[3]
      try: content = content.markdownToHtml() except MarkdownError: discard
      results.add(
        SearchResult(
          kind: SearchResultKind(rowFT[^1].parseInt()),
          threadId: rowFT[0].parseInt(),
          threadTitle: rowFT[1],
          postId: rowFT[2].parseInt(),
          postContent: content,
          creation: rowFT[4].parseInt(),
          author: selectUser(rowFT[6 .. 12]),
          postPosition: rowFT[5].parseInt(),
        )
      )

    resp Http200, $(%results), "application/json"

  get re"/(.*)":
    cond request.matches[0].splitFile.ext == ""
    resp karaxHtml
