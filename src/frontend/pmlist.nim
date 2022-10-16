import options, httpcore, json, sugar, times, strutils

import user

type
  Privmsg* = object
    id*: int
    author*: User
    creation*: int64
    content*: string
    topic*: string
    recipient*: string

  PrivmsgList* = ref object
    privmsgs*: seq[Privmsg]
    pages*: int

when defined(js):
  from dom import document
  include karax/prelude
  import karax/[kajax, kdom, i18n]
  import karaxutils, error, user, threadlist, mainbuttons

  type
    State = ref object
      list: Option[PrivmsgList]
      loading: bool
      mainButtons: MainButtons
      status: HttpCode

  var state: State

  proc newState(): State =
    State(
      list: none[PrivmsgList](),
      loading: false,
      mainButtons: newMainButtons(),
      status: Http200,
    )

  state = newState()


  proc onPrivmsgsRetrieved(httpStatus: int, response: kstring) =
    state.loading = false
    state.status = httpStatus.HttpCode
    if state.status != Http200: return

    let parsed = parseJson($response)
    let list = to(parsed, PrivmsgList)

    if state.list.isSome:
      state.list.get().privmsgs.add(list.privmsgs)
    else:
      state.list = some(list)


  proc paginate(startPos: int, totalUsers: int, perPage: int): VNode =
    result = buildHtml(tdiv):
      if totalUsers > perPage:

          a(class="chip",
            href=makeUri("/pm")):
            text "<"

            
          var current = (startPos div perPage)*perPage
          if startPos > totalUsers: current = 0

          for n in countup(current-perPage*3, current+perPage*3, perPage):
            if n<=totalUsers and n>=(current+perPage div 2) and n<=(current+perPage*3):
              a(class="chip",
                href=makeUri("/pm/" & $n)):
                text $(n div perPage + 1)
            elif n>=0 and n<=(current-perPage div 2) and n>=(current-perPage*3):
              a(class="chip",
                href=makeUri("/pm/" & $n)):
                text $(n div perPage + 1)
            elif n>=0 and n==current:
              span(class="chip active"):
                text $(n div perPage + 1)


          a(class="chip",
            href=makeUri("/pm/" & $((totalUsers div perPage)*perPage))):
            text ">"


  proc renderPrivmsgs(currentUser: Option[User], startPage: int): VNode =
      if state.status != Http200:
        return renderError("Couldn't retrieve private messages.", state.status)

      if state.list.isNone:
        if not state.loading:
          state.loading = true
          var params = @[("start", $startPage)]
          ajaxGet(makeUri("pm.json", params), @[], onPrivmsgsRetrieved)
          
        return buildHtml(tdiv(class="loading loading-lg"))
        
      let list = state.list.get()
      
      return buildHtml():
        section(class="container grid-xl"):            
          tdiv(id="thread-title", class="title"):
            p(class="title-text"): text (i18n"Private Messages" % [])

            a(href="/users", class="pm-btn"):
              button(class="btn-link btn"):
                text (i18n"Users" % [])
            a(href="/newpm", class="pm-btn"):
              button(class="btn-link btn"):
                text (i18n"Reply" % [])

          tdiv(class="py-2"):
            paginate(startPage, list.pages-1, 20)

          tdiv(class="posts"):
            for i in 0 ..< list.privmsgs.len:
              tdiv(class="post", id = $list.privmsgs[i].id):
                tdiv(class="post-icon"):
                  render(list.privmsgs[i].author, "post-avatar")
                tdiv(class="post-main"):
                  tdiv(class="post-title"):
                    tdiv(class="post-username"):
                      text list.privmsgs[i].author.name
                      renderUserRank(list.privmsgs[i].author)
                      italic(class="far fa-paper-plane mr-2")
                      text list.privmsgs[i].recipient
                    tdiv(class="post-metadata"):
                      text renderActivity(list.privmsgs[i].creation)
                  tdiv(class="post-title"):
                    tdiv(class="post-username"):
                      text list.privmsgs[i].topic
                  tdiv(class="post-content"):
                    verbatim(list.privmsgs[i].content)
            tdiv(class="py-2"):
              paginate(startPage, list.pages-1, 20)

  proc renderPrivmsgList*(currentUser: Option[User], startPage: int): VNode =
    result = buildHtml(tdiv):
      state.mainButtons.render(currentUser)
      renderPrivmsgs(currentUser, startPage)
