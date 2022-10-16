when defined(js):
  import sugar, httpcore, options, json
  import dom except Event
  import jsffi except `&`

  include karax/prelude
  import karax / [kajax, kdom, i18n]

  import error
  import karaxutils

  type
    SignupModal* = ref object
      shown: bool
      loading: bool
      onSignUp, onLogIn: proc ()
      error: Option[PostError]

  proc onSignUpPost(httpStatus: int, response: kstring, state: SignupModal) =
    postFinished:
      state.shown = false
      state.onSignUp()

  proc onSignUpClick(ev: Event, n: VNode, state: SignupModal) =
    state.loading = true
    state.error = none[PostError]()

    let uri = makeUri("signup")
    let form = dom.document.getElementById("signup-form")
    # TODO: This is a hack, karax should support this.
    let formData = newFormData(form)
    ajaxPost(uri, @[], formData.to(cstring),
             (s: int, r: kstring) => onSignUpPost(s, r, state))

  proc onClose(ev: Event, n: VNode, state: SignupModal) =
    state.shown = false
    ev.preventDefault()

  proc newSignupModal*(onSignUp, onLogIn: proc ()): SignupModal =
    SignupModal(
      shown: false,
      onLogIn: onLogIn,
      onSignUp: onSignUp
    )

  proc show*(state: SignupModal) =
    state.shown = true

  proc render*(state: SignupModal, recaptchaSiteKey: Option[string]): VNode =
    setForeignNodeId("recaptcha")

    result = buildHtml():
      tdiv(class=class({"active": state.shown}, "modal"),
           id="signup-modal"):
        a(href="", class="modal-overlay", "aria-label"="close",
          onClick=(ev: Event, n: VNode) => onClose(ev, n, state))
        tdiv(class="modal-container"):
          tdiv(class="modal-header"):
            a(href="", class="btn btn-clear float-right",
              "aria-label"="close",
              onClick=(ev: Event, n: VNode) => onClose(ev, n, state))
            tdiv(class="modal-title h5"):
              text (i18n"Create a new account" % [])
          tdiv(class="modal-body"):
            tdiv(class="content"):
              form(id="signup-form"):
                genFormField(state.error, "email", "Email", "email", false)
                genFormField(state.error, "username", $(i18n"Username" % []), "text", false)
                genFormField(
                  state.error,
                  "password",
                  $(i18n"Password" % []),
                  "password",
                  true
                )
                if recaptchaSiteKey.isSome:
                  tdiv(id="recaptcha"):
                    tdiv(class="h-captcha",
                         "data-sitekey"=recaptchaSiteKey.get())
                    script(src="https://hcaptcha.com/1/api.js")
          tdiv(class="modal-footer"):
            button(class=class({"loading": state.loading},
                               "btn btn-primary create-account-btn"),
                   onClick=(ev: Event, n: VNode) => onSignUpClick(ev, n, state)):
              text (i18n"Create account" % [])
            button(class="btn login-btn",
                   onClick=(ev: Event, n: VNode) =>
                    (state.onLogIn(); state.shown = false)):
              text $(i18n"Log in" % [])

            p(class="license-text text-gray"):
              text "By registering, you agree to the "
              a(id="license", href=makeUri("/about/license"),
                onClick=(ev: Event, n: VNode) =>
                    (state.shown = false; anchorCB(ev, n))):
                text "content license"
              text "."
