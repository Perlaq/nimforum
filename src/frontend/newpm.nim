when defined(js):
  import sugar, httpcore, options, json
  import dom except Event
  import jsffi except `&`

  include karax/prelude
  import karax / [kajax, kdom, i18n]

  import error, replybox, threadlist, post, user
  import karaxutils

  type
    NewPrivmsg* = ref object
      loading: bool
      error: Option[PostError]
      replyBox: ReplyBox
      subject: kstring
      recipient: kstring

  proc newNewPrivmsg*(): NewPrivmsg =
    NewPrivmsg(
      replyBox: newReplyBox(nil),
      subject: "",
      recipient: ""
    )

  proc onSubjectChange(e: Event, n: VNode, state: NewPrivmsg) =
    state.subject = n.value
    
  proc onRecipientChange(e: Event, n: VNode, state: NewPrivmsg) =
    state.recipient = n.value

  proc onCreatePost(httpStatus: int, response: kstring, state: NewPrivmsg) =
    postFinished:
      let j = parseJson($response)
      let response = to(j, array[2, int])
      navigateTo("/pm")

  proc onCreateClick(ev: Event, n: VNode, state: NewPrivmsg) =
    state.loading = true
    state.error = none[PostError]()

    let uri = makeUri("newpm")
    # TODO: This is a hack, karax should support this.
    let formData = newFormData()

    formData.append("subject", state.subject)
    formData.append("msg", state.replyBox.getText())
    formData.append("recipient", state.recipient)

    ajaxPost(uri, @[], formData.to(cstring),
             (s: int, r: kstring) => onCreatePost(s, r, state))

  proc render*(state: NewPrivmsg, currentUser: Option[User]): VNode =
    result = buildHtml():
      section(class="container grid-xl"):
        tdiv(id="new-thread"):
          tdiv(class="title"):
            p(): text (i18n"Private Messages" % [])
          tdiv(class="content"):
            input(id="pm-title", class="form-input mb-2", `type`="text", name="subject",
                  placeholder=(i18n"Type the title here" % []),
                  oninput=(e: Event, n: VNode) => onSubjectChange(e, n, state))
            if state.error.isSome():
              p(class="text-error"):
                text state.error.get().message
            tdiv():
              a(href="/users", target="_blank"):
                text (i18n"Users" % [])
            input(id="pm-recipient", class="form-input mb-2", `type`="text", name="recepient",
                  placeholder=(i18n"Type the recipient here" % []),
                  oninput=(e: Event, n: VNode) => onRecipientChange(e, n, state))
                  
            renderContent(state.replyBox, none[Thread](), none[Post]())
          tdiv(class="footer"):

            button(id="create-pm-btn",
                   class=class(
                     {"loading": state.loading},
                     "btn btn-primary"
                   ),
                   onClick=(ev: Event, n: VNode) =>
                    (onCreateClick(ev, n, state))):
              text (i18n"Reply" % [])
