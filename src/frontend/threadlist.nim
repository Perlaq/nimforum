import strformat, times, options, json, httpcore, sugar

import category, user

type
  Thread* = object
    id*: int
    topic*: string
    category*: Category
    author*: User
    users*: seq[User]
    replies*: int
    views*: int
    lastPost*: int
    activity*: int64 ## Unix timestamp
    creation*: int64 ## Unix timestamp
    isLocked*: bool
    isSolved*: bool
    isPinned*: bool

  ThreadList* = ref object
    threads*: seq[Thread]
    moreCount*: int ## How many more threads are left

proc isModerated*(thread: Thread): bool =
  ## Determines whether the specified thread is under moderation.
  ## (i.e. whether the specified thread is invisible to ordinary users).
  thread.author.rank <= Moderated

when defined(js):
  import sugar
  include karax/prelude
  import karax / [vstyles, kajax, kdom, i18n]

  import karaxutils, error, user, mainbuttons, post

  type
    State = ref object
      list: Option[ThreadList]
      refreshList: bool
      loading: bool
      status: HttpCode
      mainButtons: MainButtons

  var state: State

  proc newState(): State =
    State(
      list: none[ThreadList](),
      loading: false,
      status: Http200,
      mainButtons: newMainButtons(
        onCategoryChange =
          (oldCategory: Category, newCategory: Category) => (state.list = none[ThreadList]())
      )
    )

  state = newState()

  proc visibleTo*[T](thread: T, user: Option[User]): bool =
    ## Determines whether the specified thread (or post) should be
    ## shown to the user. This procedure is generic and works on any
    ## object with a `isModerated` proc.
    ##
    ## The rules for this are determined by the rank of the user, their
    ## settings (TODO), and whether the thread's creator is moderated or not.
    ##
    ## The ``user`` argument refers to the currently logged in user.
    mixin isModerated
    if user.isNone(): return not thread.isModerated

    let rank = user.get().rank
    if rank < Rank.Moderator and thread.isModerated:
      return thread.author == user.get()

    return true

  proc genUserAvatars(users: seq[User]): VNode =
    result = buildHtml(td(class="thread-users")):
      for user in users:
        render(user, "avatar avatar-sm", showStatus=true)
        text " "

  proc renderActivity*(activity: int64): string =
    let currentTime = getTime()
    let activityTime = fromUnix(activity)
    let duration = currentTime - activityTime
    if currentTime.local().year != activityTime.local().year:
      return activityTime.local().format("MMM yyyy")
    elif duration.inDays > 30 and duration.inDays < 300:
      return activityTime.local().format("MMM dd")
    elif duration.inDays != 0:
      return $duration.inDays & "d"
    elif duration.inHours != 0:
      return $duration.inHours & "h"
    elif duration.inMinutes != 0:
      return $duration.inMinutes & "m"
    else:
      return $duration.inSeconds & "s"

  proc genLastPost(thread: Thread, act: string, isNew: bool, isOld: bool): VNode =
    result = buildHtml():
      let pos = PostLink(postPosition : thread.replies, 
                         threadId : thread.id,
                         postId : thread.lastPost)

      a(class=class({"is-new": isNew, "is-old": isOld}, "thread-time"),
        href=renderPostUrl(pos)):
        text act

  proc genThread(pos: int, thread: Thread, isNew: bool, noBorder: bool, displayCategory=true, isUnseen: bool): VNode =
    let isOld = (getTime() - thread.creation.fromUnix).inWeeks > 2
    let isBanned = thread.author.rank.isBanned()
    result = buildHtml():
      tr(class=class({"no-border": noBorder, "banned": isBanned, "pinned": thread.isPinned, "thread-" & $pos: true})):
        td(class="thread-title"):
          if thread.isLocked:
            italic(class="fas fa-lock fa-xs",
                   title="Thread cannot be replied to")
          if thread.isPinned:
            italic(class="fas fa-thumbtack fa-xs", 
                   title="Pinned post")
          if isBanned:
            italic(class="fas fa-ban fa-xs",
                   title="Thread author is banned")
          if thread.isModerated:
            italic(class="fas fa-eye-slash fa-xs",
                   title="Thread is moderated")
          if thread.isSolved:
            italic(class="fas fa-check-square fa-xs",
                   title="Thread has a solution")
          a(href=makeUri("/t/" & $thread.id), onClick=anchorCB):
            text thread.topic
          tdiv(class="show-sm" & class({"d-none": not displayCategory})):
            render(thread.category)
          if isUnseen:
            a(href=makeUri("/unread/" & $thread.id)):
              italic(class="ml-1 far fa-envelope-open fa-xs",
                title="Go to the first unread message")

                  
        td(class="hide-sm" & class({"d-none": not displayCategory})):
          render(thread.category)
        genUserAvatars(thread.users)
        td(class="thread-replies"): text $thread.replies
        td(class="hide-sm" & class({
            "views-text": thread.views < 999,
            "popular-text": thread.views > 999 and thread.views < 5000,
            "super-popular-text": thread.views > 5000
        })):
          if thread.views > 999:
            text fmt"{thread.views/1000:.1f}k"
          else:
            text $thread.views

        let friendlyCreation = thread.creation.fromUnix.local.format(
          "'First post:' MMM d, yyyy HH:mm'\n'"
        )
        let friendlyActivity = thread.activity.fromUnix.local.format(
          "'Last reply:' MMM d, yyyy HH:mm"
        )
        td(class=class({"is-new": isNew, "is-old": isOld}, "thread-time"),
           title=friendlyCreation & friendlyActivity):
          genLastPost(thread, renderActivity(thread.activity), isNew, isOld)

  proc onThreadList(httpStatus: int, response: kstring) =
    state.loading = false
    state.status = httpStatus.HttpCode
    if state.status != Http200: return

    let parsed = parseJson($response)
    let list = to(parsed, ThreadList)

    if state.list.isSome:
      state.list.get().threads.add(list.threads)
      state.list.get().moreCount = list.moreCount
    else:
      state.list = some(list)

  proc onLoadMore(ev: Event, n: VNode, categoryId: Option[int]) =
    state.loading = true
    let start = state.list.get().threads.len
    if categoryId.isSome:
      ajaxGet(makeUri("threads.json?start=" & $start & "&categoryId=" & $categoryId.get()), @[], onThreadList)
    else:
      ajaxGet(makeUri("threads.json?start=" & $start), @[], onThreadList)

  proc getInfo(
    list: seq[Thread], i: int, currentUser: Option[User]
  ): tuple[isLastUnseen, isNew: bool, isUnseen: bool] =
    ## Determines two properties about a thread.
    ##
    ## * isLastUnseen - Whether this is the last thread that had new
    ## activity since the last time the user visited the forum.
    ## * isNew - Whether this thread was created during the time that the
    #            user was absent from the forum.
    let previousVisitAt =
      if currentUser.isSome(): currentUser.get().previousVisitAt
      else: getTime().toUnix
    assert previousVisitAt != 0

    let thread = list[i]
    let isUnseen = thread.activity > previousVisitAt
    let isNextUnseen = i+1 < list.len and list[i+1].activity > previousVisitAt

    return (
      isLastUnseen: isUnseen and (not isNextUnseen),
      isNew: thread.creation > previousVisitAt,
      isUnseen: isUnseen
    )

  proc genThreadList(currentUser: Option[User], categoryId: Option[int]): VNode =
    if state.status != Http200:
      return renderError("Couldn't retrieve threads.", state.status)

    if state.list.isNone:
      if not state.loading:
        state.loading = true
        if categoryId.isSome:
          ajaxGet(makeUri("threads.json?categoryId=" & $categoryId.get()), @[], onThreadList)
        else:
          ajaxGet(makeUri("threads.json"), @[], onThreadList)

      return buildHtml(tdiv(class="loading loading-lg"))

    let displayCategory = categoryId.isNone

    let list = state.list.get()
    result = buildHtml():
      section(class="thread-list"):
        table(class="table", id="threads-list"):
          thead():
            tr:
              th(text (i18n"Topic" % []))
              th(class="hide-sm" & class({"d-none": not displayCategory})): text (i18n"Category" % [])
              th(class="thread-users"): text (i18n"Users" % [])
              th(class="centered-header"): text (i18n"Replies" % [])
              th(class="hide-sm centered-header"): text (i18n"Views" % [])
              th(class="centered-header"): text (i18n"Activity" % [])
          tbody():
            for i in 0 ..< list.threads.len:
              let thread = list.threads[i]
              if not visibleTo(thread, currentUser): continue

              let isLastThread = i+1 == list.threads.len
              let (isLastUnseen, isNew, isUnseen) = getInfo(list.threads, i, currentUser)
              genThread(i+1, thread, isNew,
                        noBorder=isLastUnseen or isLastThread,
                        displayCategory=displayCategory, isUnseen)
              if isLastUnseen and (not isLastThread):
                tr(class="last-visit-separator"):
                  td(colspan="6"):
                    span(text "last visit")

            if list.moreCount > 0:
              tr(class="load-more-separator"):
                if state.loading:
                  td(colspan="6"):
                    tdiv(class="loading loading-lg")
                else:
                  td(colspan="6",
                     onClick = (ev: Event, n: VNode) => (onLoadMore(ev, n, categoryId))):
                    span(text "load more threads")

  proc renderThreadList*(currentUser: Option[User], categoryId = none(int)): VNode =
    result = buildHtml(tdiv):
      state.mainButtons.render(currentUser, categoryId=categoryId)
      genThreadList(currentUser, categoryId)
