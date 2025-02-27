
when defined(js):
  import sugar

  include karax/prelude
  import karax/[vstyles, i18n]
  import karaxutils

  import user
  type
    UserMenu* = ref object
      shown: bool
      user: User
      onLogout: proc ()

  proc newUserMenu*(onLogout: proc ()): UserMenu =
    UserMenu(
      shown: false,
      onLogout: onLogout
    )

  proc onClick(e: Event, n: VNode, state: UserMenu) =
    state.shown = not state.shown

  proc render*(state: UserMenu, user: User): VNode =
    result = buildHtml():
      tdiv(id="profile-btn"):
        figure(class="avatar c-hand",
               onClick=(e: Event, n: VNode) => onClick(e, n, state)):
          img(src=user.avatarUrl, title=user.name)
          if user.isOnline:
            italic(class="avatar-presense online")

        tdiv(style=style([
               (StyleAttr.width, kstring"999999px"),
               (StyleAttr.height, kstring"999999px"),
               (StyleAttr.position, kstring"absolute"),
               (StyleAttr.left, kstring"0"),
               (StyleAttr.top, kstring"0"),
               (
                 StyleAttr.display,
                 if state.shown: kstring"block" else: kstring"none"
               )
             ]),
             onClick=(e: Event, n: VNode) => (state.shown = false))

        ul(class="menu menu-right", style=style(
          StyleAttr.display, if state.shown: "inherit" else: "none"
        )):
          li(class="menu-item"):
            tdiv(class="tile tile-centered"):
              tdiv(class="tile-icon"):
                img(class="avatar", src=user.avatarUrl,
                    title=user.name)
              tdiv(id="profile-name", class="tile-content"):
                text user.name
          li(class="divider")
          li(class="menu-item"):
            a(id="myprofile-btn",
              href=makeUri("/profile/" & user.name)):
              text (i18n"My profile" % [])
          li(class="menu-item"):
            a(id="users-btn",
              href=makeUri("/pm")):
              text (i18n"PM" % [])
          li(class="menu-item c-hand"):
            a(id="logout-btn",
              onClick = (e: Event, n: VNode) =>
                (state.shown=false; state.onLogout())):
              text (i18n"Logout" % [])
