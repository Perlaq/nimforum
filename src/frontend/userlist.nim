import options, httpcore, json, sugar, times, strutils

import user

type
  UserList* = ref object
    users*: seq[User]
    pages*: int

when defined(js):
  from dom import document
  include karax/prelude
  import karax/[kajax, kdom, i18n]
  import karaxutils, error, user, threadlist, mainbuttons

  type
    State = ref object
      list: Option[UserList]
      loading: bool
      mainButtons: MainButtons
      status: HttpCode

  var state: State

  proc newState(): State =
    State(
      list: none[UserList](),
      loading: false,
      mainButtons: newMainButtons(),
      status: Http200,
    )

  state = newState()


  proc onUsersRetrieved(httpStatus: int, response: kstring) =
    state.loading = false
    state.status = httpStatus.HttpCode
    if state.status != Http200: return

    let parsed = parseJson($response)
    let list = to(parsed, UserList)

    if state.list.isSome:
      state.list.get().users.add(list.users)
    else:
      state.list = some(list)


  proc paginate(startPos: int, totalUsers: int, perPage: int): VNode =
    result = buildHtml(tdiv):
      if totalUsers > perPage:

          a(class="chip",
            href=makeUri("/users")):
            text "<"

            
          var current = (startPos div perPage)*perPage
          if startPos > totalUsers: current = 0

          for n in countup(current-perPage*3, current+perPage*3, perPage):
            if n<=totalUsers and n>=(current+perPage div 2) and n<=(current+perPage*3):
              a(class="chip",
                href=makeUri("/users/" & $n)):
                text $(n div perPage + 1)
            elif n>=0 and n<=(current-perPage div 2) and n>=(current-perPage*3):
              a(class="chip",
                href=makeUri("/users/" & $n)):
                text $(n div perPage + 1)
            elif n>=0 and n==current:
              span(class="chip active"):
                text $(n div perPage + 1)


          a(class="chip",
            href=makeUri("/users/" & $((totalUsers div perPage)*perPage))):
            text ">"


  proc renderUsers(currentUser: Option[User], startPage: int): VNode =
      if state.status != Http200:
        return renderError("Couldn't retrieve users.", state.status)

      if state.list.isNone:
        if not state.loading:
          state.loading = true
          var params = @[("start", $startPage)]
          ajaxGet(makeUri("users.json", params), @[], onUsersRetrieved)
          
        return buildHtml(tdiv(class="loading loading-lg"))
        
      let list = state.list.get()
      
      return buildHtml():
        section(class="category-list"):
          tdiv(class="flex-centered"):
            italic(class="fas fa-chart-bar mr-1")
            text $list.pages
          tdiv(class="py-2"):
            paginate(startPage, list.pages-1, 40)
            
          tdiv(class="columns"):
            for i in 0 ..< list.users.len:
              tdiv(class="column col-sm-6 col-md-4 col-3 "):
                tdiv(class="profile"):
                  tdiv(class="profile-icon"):
                    render(list.users[i], "post-avatar")
                  tdiv(class="profile-content"):
                    tdiv(class="profile-title text-bold"):
                      text list.users[i].name
                    tdiv(class="text-gray"):
                      text renderActivity(list.users[i].lastOnline)

          tdiv(class="py-2"):        
            paginate(startPage, list.pages-1, 40)

  proc renderUserList*(currentUser: Option[User], startPage: int): VNode =
    result = buildHtml(tdiv):
      state.mainButtons.render(currentUser)
      renderUsers(currentUser, startPage)
