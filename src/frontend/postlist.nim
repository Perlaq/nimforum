
import system except Thread
import options, json, times, httpcore, sugar, strutils
import sequtils

import threadlist, category, post, user
type

  PostList* = ref object
    thread*: Thread
    history*: seq[Thread] ## If the thread was edited this will contain the
                          ## older versions of the thread (title/category
                          ## changes). TODO
    posts*: seq[Post]

when defined(js):
  from dom import document
  import jsffi except `&`

  include karax/prelude
  import karax / [kajax, kdom, i18n]

  import karaxutils, error, replybox, editbox, postbutton, delete
  import categorypicker

  type
    State = ref object
      list: Option[PostList]
      loading: bool
      status: HttpCode
      error: Option[PostError]
      replyingTo: Option[Post]
      replyBox: ReplyBox
      editing: Option[Post] ## If in edit mode, this contains the post.
      editBox: EditBox
      likeButton: LikeButton
      deleteModal: DeleteModal
      lockButton: LockButton
      pinButton: PinButton
      categoryPicker: CategoryPicker

  proc onReplyPosted(id: int)
  proc onCategoryChanged(oldCategory: Category, newCategory: Category)
  proc onEditPosted(id: int, content: string, subject: Option[string])
  proc onEditCancelled()
  proc onDeletePost(post: Post)
  proc onDeleteThread(thread: Thread)
  proc newState(): State =
    State(
      list: none[PostList](),
      loading: false,
      status: Http200,
      error: none[PostError](),
      replyingTo: none[Post](),
      replyBox: newReplyBox(onReplyPosted),
      editBox: newEditBox(onEditPosted, onEditCancelled),
      likeButton: newLikeButton(),
      deleteModal: newDeleteModal(onDeletePost, onDeleteThread, nil),
      lockButton: newLockButton(),
      pinButton: newPinButton(),
      categoryPicker: newCategoryPicker(onCategoryChanged)
    )

  var
    state = newState()

  proc onCategoryPost(httpStatus: int, response: kstring, state: State) =
    state.loading = false
    postFinished:
      discard
      # TODO: show success message

  proc onCategoryChanged(oldCategory: Category, newCategory: Category) =
    let uri = makeUri("/updateThread")

    let formData = newFormData()
    formData.append("threadId", $state.list.get().thread.id)
    formData.append("category", $newCategory.id)

    state.loading = true

    ajaxPost(uri, @[], formData.to(cstring),
             (s: int, r: kstring) => onCategoryPost(s, r, state))

  proc onPostList(httpStatus: int, response: kstring, postId: Option[int]) =
    state.loading = false
    state.status = httpStatus.HttpCode
    if state.status != Http200: return

    let parsed = parseJson($response)
    let list = to(parsed, PostList)

    state.list = some(list)

    dom.document.title = list.thread.topic & " - " & dom.document.title
    state.categoryPicker.select(list.thread.category.id)

    # The anchor should be jumped to once all the posts have been loaded.
    if postId.isSome():
      discard setTimeout(
        () => (
          # Would have used scrollIntoView but then the `:target` selector
          # isn't activated.
          getVNodeById($postId.get()).dom.scrollIntoView()
        ),
        100
      )

  proc onMorePosts(httpStatus: int, response: kstring, start: int) =
    state.loading = false
    state.status = httpStatus.HttpCode
    if state.status != Http200: return

    let parsed = parseJson($response)
    var list = to(parsed, seq[Post])

    var idsLoaded: seq[int] = @[]
    for i in 0..<list.len:
      state.list.get().posts.insert(list[i], i+start)
      idsLoaded.add(list[i].id)

    # Save a list of the IDs which have not yet been loaded into the top-most
    # post.
    let postIndex = start+list.len
    # The following check is necessary because we reuse this proc to load
    # a newly created post.
    if postIndex < state.list.get().posts.len:
      let post = state.list.get().posts[postIndex]
      var newPostIds: seq[int] = @[]
      for id in post.moreBefore:
        if id notin idsLoaded:
          newPostIds.add(id)
      post.moreBefore = newPostIds

  proc loadMore(start: int, ids: seq[int]) =
    if state.loading: return

    state.loading = true
    let uri = makeUri(
      "specific_posts.json",
      [("ids", $(%ids))]
    )
    ajaxGet(
      uri,
      @[],
      (s: int, r: kstring) => onMorePosts(s, r, start)
    )

  proc onReplyPosted(id: int) =
    ## Executed when a reply has been successfully posted.
    loadMore(state.list.get().posts.len, @[id])

  proc onEditCancelled() = state.editing = none[Post]()

  proc onEditPosted(id: int, content: string, subject: Option[string]) =
    ## Executed when an edit has been successfully posted.
    state.editing = none[Post]()
    let list = state.list.get()
    for i in 0 ..< list.posts.len:
      if list.posts[i].id == id:
        list.posts[i].history.add(PostInfo(
          creation: getTime().toUnix(),
          content: content
        ))
        break

  proc onReplyClick(e: Event, n: VNode, p: Option[Post]) =
    state.replyingTo = p
    state.replyBox.show()
    
  proc onMDContent(httpStatus: int, response: kstring, author: string) =
    state.loading = false
    state.status = httpStatus.HttpCode
    if state.status != Http200: return
    let rawContent = ">" & author & (i18n" wrote" % []) & 
      ":\n>\n>" & ($response).replace("\n","\n>") & "\n\n"
    state.replyBox.setText(state.replyBox.getText & $rawContent)
    dom.document.getElementById("reply-textarea").value = $(state.replyBox.getText)
    
  proc onQuoteClick(e: Event, n: VNode, id: int, author: string) =
    var params = @[("id", $id)]
    let uri = makeUri("post.md", params)
    ajaxGet(uri, @[], (s: int, r: kstring) => onMDContent(s, r, author))
    state.replyBox.show()

  proc onEditClick(e: Event, n: VNode, p: Post) =
    state.editing = some(p)

    # TODO: Ensure the edit box is as big as its content. Auto resize the
    # text area.

  proc onDeletePost(post: Post) =
    state.list.get().posts.keepIf(
      x => x.id != post.id
    )

  proc onDeleteThread(thread: Thread) =
    window.location.href = makeUri("/")

  proc onDeleteClick(e: Event, n: VNode, p: Post) =
    let list = state.list.get()
    if list.posts[0].id == p.id:
      state.deleteModal.show(list.thread)
    else:
      state.deleteModal.show(p)

  proc onLoadMore(ev: Event, n: VNode, start: int, post: Post) =
    loadMore(start, post.moreBefore) # TODO: Don't load all!

  proc genLoadMore(post: Post, start: int): VNode =
    result = buildHtml():
      tdiv(class="information load-more-posts",
           onClick=(e: Event, n: VNode) => onLoadMore(e, n, start, post)):
        tdiv(class="information-icon"):
          italic(class="fas fa-comment-dots")
        tdiv(class="information-main"):
          if state.loading:
            tdiv(class="loading loading-lg")
          else:
            tdiv(class="information-title"):
              text "Load more posts "
              span(class="more-post-count"):
                text "(" & $post.moreBefore.len & ")"

  proc genCategories(thread: Thread, currentUser: Option[User]): VNode =
    let loggedIn = currentUser.isSome()
    let authoredByUser =
      loggedIn and currentUser.get().name == thread.author.name
    let canChangeCategory =
      loggedIn and currentUser.get().rank in {Admin, Moderator}

    result = buildHtml():
      tdiv(class="d-inline-block"):
        if authoredByUser or canChangeCategory:
          render(state.categoryPicker, currentUser, compact=false)
        else:
          render(thread.category)

  proc genPostButtons(post: Post, currentUser: Option[User]): Vnode =
    let loggedIn = currentUser.isSome()
    let authoredByUser =
      loggedIn and currentUser.get().name == post.author.name
    let currentAdmin =
      currentUser.isSome() and currentUser.get().rank == Admin

    # Don't show buttons if the post is being edited.
    if state.editing.isSome() and state.editing.get() == post:
      return buildHtml(tdiv())

    result = buildHtml():
      tdiv(class="post-buttons"):
        if authoredByUser or currentAdmin:
          tdiv(class="edit-button", onClick=(e: Event, n: VNode) =>
               onEditClick(e, n, post)):
            button(class="btn"):
              italic(class="far fa-edit")
          tdiv(class="delete-button",
               onClick=(e: Event, n: VNode) => onDeleteClick(e, n, post)):
            button(class="btn"):
              italic(class="far fa-trash-alt")

        render(state.likeButton, post, currentUser)

        if loggedIn:
          tdiv(class="flag-button"):
            button(class="btn"):
              italic(class="far fa-flag")

          tdiv(class="quote-button"):
            button(class="btn", onClick=(e: Event, n: VNode) =>
                   onQuoteClick(e, n, post.id, post.author.name)):
              italic(class="fas fa-quote-left")

          tdiv(class="reply-button"):
            button(class="btn", onClick=(e: Event, n: VNode) =>
                   onReplyClick(e, n, some(post))):
              italic(class="fas fa-reply")
              text (i18n" Reply" % [])

  proc genPost(
    post: Post, thread: Thread, currentUser: Option[User], highlight: bool
  ): VNode =
    let postCopy = post # TODO: Another workaround here, closure capture :(

    let originalPost = thread.author == post.author

    result = buildHtml():
      tdiv(class=class({"highlight": highlight, "original-post": originalPost}, "post"),
           id = $post.id):
        tdiv(class="post-icon"):
          render(post.author, "post-avatar")
        tdiv(class="post-main"):
          tdiv(class="post-title"):
            tdiv(class="post-username"):
              text post.author.name
              renderUserRank(post.author)
            tdiv(class="post-metadata"):
              if post.replyingTo.isSome():
                let replyingTo = post.replyingTo.get()
                tdiv(class="post-replyingTo"):
                  a(href=renderPostUrl(replyingTo)):
                    italic(class="fas fa-reply")
                  renderUserMention(replyingTo.author.get())
              if post.history.len > 0:
                let title = post.lastEdit.creation.fromUnix().local.
                            format("'Last modified' MMM d, yyyy HH:mm")
                tdiv(class="post-history", title=title):
                  span(class="edit-count"):
                    text $post.history.len
                  italic(class="fas fa-pencil-alt")

              let title = post.info.creation.fromUnix().local.
                          format("MMM d, yyyy HH:mm")
              a(href=renderPostUrl(post, thread), title=title):
                text renderActivity(post.info.creation)
          tdiv(class="post-content"):
            if state.editing.isSome() and state.editing.get() == post:
              render(state.editBox, postCopy)
            else:
              let content =
                if post.history.len > 0:
                  post.lastEdit.content
                else:
                  post.info.content
              verbatim(content)

          genPostButtons(postCopy, currentUser)

  proc genTimePassed(prevPost: Post, post: Option[Post], last: bool): VNode =
    var latestTime =
      if post.isSome: post.get().info.creation.fromUnix()
      else: getTime()

    # TODO: Use `between` once it's merged into stdlib.
    let
      tmpl =
        if last: [
            "A long time since last reply",
            "$1 year since last reply",
            "$1 years since last reply",
            "$1 month since last reply",
            "$1 months since last reply",
          ]
        else: [
          "Some time later",
          "$1 year later", "$1 years later",
          "$1 month later", "$1 months later"
        ]
    var diffStr = tmpl[0]
    let diff = latestTime - prevPost.info.creation.fromUnix()
    if diff.inWeeks > 48:
      let years = diff.inWeeks div 48
      diffStr =
        (if years == 1: tmpl[1] else: tmpl[2]) % $years
    elif diff.inWeeks > 4:
      let months = diff.inWeeks div 4
      diffStr =
        (if months == 1: tmpl[3] else: tmpl[4]) % $months
    else:
      return buildHtml(tdiv())

    # PROTIP: Good thread ID to test this with is: 1267.
    result = buildHtml():
      tdiv(class="information time-passed"):
        tdiv(class="information-icon"):
          italic(class="fas fa-clock")
        tdiv(class="information-main"):
          tdiv(class="information-title"):
            text diffStr

  proc paginate(threadId: int, startPos: int, totalReplies: int, perPage: int): VNode =
    result = buildHtml(tdiv):
      if totalReplies > perPage:

          a(class="chip",
            href=makeUri("/t/" & $threadId)):
            text "<"

            
          var current = (startPos div perPage)*perPage
          if startPos > totalReplies: current = 0

          for n in countup(current-perPage*3, current+perPage*3, perPage):
            if n<=totalReplies and n>=(current+perPage div 2) and n<=(current+perPage*3):
              a(class="chip",
                href=makeUri("/t/" & $threadId & "/s/" & $n)):
                text $(n div perPage + 1)
            elif n>=0 and n<=(current-perPage div 2) and n>=(current-perPage*3):
              a(class="chip",
                href=makeUri("/t/" & $threadId & "/s/" & $n)):
                text $(n div perPage + 1)
            elif n>=0 and n==current:
              span(class="chip active"):
                text $(n div perPage + 1)


          a(class="chip",
            href=makeUri("/t/" & $threadId & "/s/" & $((totalReplies div perPage)*perPage))):
            text ">"

  proc genLastPost(thread: Thread): VNode =
    result = buildHtml():
      let pos = PostLink(postPosition : thread.replies, 
                         threadId : thread.id,
                         postId : thread.lastPost)
      a(class="category-status",
        href=renderPostUrl(pos)):
        button(class="plus-btn btn btn-link"):
          italic(class="fas fa-level-down-alt")

  proc renderPostList*(threadId: int, startPos: int, postId: Option[int],
                       currentUser: Option[User]): VNode =
    if state.list.isSome() and state.list.get().thread.id != threadId:
      state.list = none[PostList]()
      state.status = Http200

    if state.status != Http200:
      return renderError("Couldn't retrieve posts.", state.status)

    if state.list.isNone:
      var params = @[("id", $threadId)]
      if postId.isSome():
        params.add(("anchor", $postId.get()))
      if startPos > 0:
        params.add(("start", $startPos))
      let uri = makeUri("posts.json", params)
      if not state.loading:
        state.loading = true
        ajaxGet(uri, @[], (s: int, r: kstring) => onPostList(s, r, postId))

      return buildHtml(tdiv(class="loading loading-lg"))

    let list = state.list.get()
    result = buildHtml():
      section(class="container grid-xl"):
        tdiv(id="thread-title", class="title"):
          if state.error.isSome():
            span(class="text-error"):
              text state.error.get().message
          p(class="title-text"): text list.thread.topic
          if list.thread.isLocked:
            italic(class="fas fa-lock fa-xs",
                   title="Thread cannot be replied to")
            text "Locked"
          if list.thread.isModerated:
            italic(class="fas fa-eye-slash fa-xs",
                   title="Thread is moderated")
            text "Moderated"
          if list.thread.isSolved:
            italic(class="fas fa-check-square fa-xs",
                   title="Thread has a solution")
            text "Solved" 
          genCategories(list.thread, currentUser)
          tdiv(class="d-inline-block"):
            genLastPost(list.thread)
            a(class="category-status",
              href=("#thread-buttons")):
              button(class="plus-btn btn btn-link"):
                italic(class="fas fa-angle-double-down")
            a(class="category-status",
              href=makeUri("/c/" & $list.thread.category.id)):
              button(class="plus-btn btn btn-link"):
                italic(class="fas fa-list-ul")
        tdiv(class="posts"):
          var prevPost: Option[Post] = none[Post]()
          for i, post in list.posts:
            if not post.visibleTo(currentUser):
              tdiv(class="post",  id = $post.id):
                tdiv(class="post-main"):
                  tdiv(class="post-content category-description"):
                    text "post " & $post.id & " from " &
                      post.author.name & " is hidden"
              continue
            if post.isDeleted:
              tdiv(class="post",  id = $post.id):
                tdiv(class="post-main"):
                  tdiv(class="post-content category-description"):
                    text "post " & $post.id & " from " &
                      post.author.name & " has been deleted"
              continue

            if prevPost.isSome:
              genTimePassed(prevPost.get(), some(post), false)
            if post.moreBefore.len > 0:
              genLoadMore(post, i)
            let highlight = postId.isSome() and postId.get() == post.id
            genPost(post, list.thread, currentUser, highlight)
            prevPost = some(post)

          if prevPost.isSome:
            genTimePassed(prevPost.get(), none[Post](), true)

          tdiv(id="thread-buttons"):
            button(class="btn btn-secondary",
                   onClick=(e: Event, n: VNode) =>
                         onReplyClick(e, n, none[Post]())):
              italic(class="fas fa-reply")
              text (i18n" Reply" % [])

            render(state.lockButton, list.thread, currentUser)
            render(state.pinButton, list.thread, currentUser)

            paginate(threadId, startPos, list.thread.replies, postPerPage())

          render(state.replyBox, list.thread, state.replyingTo, false)

          render(state.deleteModal)
