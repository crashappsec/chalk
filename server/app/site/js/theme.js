(function () {
  Stimulus.register(
    'mobile-nav',
    class extends Controller {
      static targets = ['toggle'];

      open() {
        if (this.isOpen) return;
        this.isOpen = true;

        this.element.classList.add('is-open');
        this.toggleTarget.setAttribute('aria-expanded', 'true')
      }

      close() {
        if (!this.isOpen) return;
        this.isOpen = false;

        this.element.classList.remove('is-open');
        this.toggleTarget.setAttribute('aria-expanded', 'false')
      }

      toggle() {
        if (this.isOpen) {
          this.close();
        } else {
          this.open();
        }
      }
    }
  );

  Stimulus.register(
    'search',
    class extends Controller {
      static targets = ['input', 'results'];

      initialize() {
        window.initSearch();

        this.resultsTarget.addEventListener('click', (ev) => {
          if (ev.target.closest('a')) {
            this.emit('modal:close', { bubbles: true })
          }
        })
      }

      input() {
        if (this.inputTarget.value.trim()) {
          this.element.classList.add('has-search-term')
        } else {
          this.element.classList.remove('has-search-term')
        }
      }

      emit(name, options, element = this.element) {
        element.dispatchEvent(new CustomEvent(name, {
          bubbles: false,
          cancelable: false,
          detail: null,
          ...options,
        }))
      }
    }
  );

  Stimulus.register(
    'newsletter',
    class extends Controller {
      static targets = ['email', 'submit'];

      submit(ev) {
        ev.preventDefault();

        if (this.isSubmitting) return;

        const email = this.emailTarget.value.trim();
        if (!email) return;

        this.isSubmitting = true;
        this.element.classList.add('is-submitting');
        this.submitTarget.disabled = true;

        fetch(
          'https://api.hsforms.com/submissions/v3/integration/submit/25939634/364d1f0e-86c5-4935-95b3-9dd42070abff',
          {
            body: JSON.stringify({
              fields: [{ name: 'email', value: email }],
            }),
            headers: { 'Content-Type': 'application/json' },
            method: 'POST',
          }
        )
          .then((res) => res.json())
          .then((data) => {
            console.log(data);

            const message =
              data && data.inlineMessage
                ? data.inlineMessage
                : 'Thanks for submitting the form.';
            this.element.innerHTML = `<p class="newsletter__message">${message}</p>`;
            this.element.classList.add('is-submitted');
            this.element.classList.remove('is-submitting');
          })
          .catch((error) => {
            console.error(error);
            this.isSubmitting = false;
            this.element.classList.remove('is-submitting');
            this.submitTarget.disabled = false;
            this.emailTarget.value = email;
          });
      }
    }
  );

  Stimulus.register(
    'dropdown',
    class extends Controller {
      static targets = ['content', 'toggle']

      get focusables() {
        if (!this.cachedFocusables) {
          this.cachedFocusables = Array.from(this.contentTarget.querySelectorAll('a')).filter(
            (link) => link.offsetWidth > 0,
          )
        }

        return this.cachedFocusables
      }

      initialize() {
        this.onClick = this.onClick.bind(this)
        this.onKeydown = this.onKeydown.bind(this)
        this.onContentTransitionEnd = this.onContentTransitionEnd.bind(this)

        this.elementOpenClass = 'is-open'
        this.elementTransitioningClass = 'is-transitioning'
        this.isOpen = this.element.classList.contains(this.elementOpenClass)

        this.toggleTarget.addEventListener('click', (ev) => {
          ev.preventDefault()
          this.toggle()
        })
        this.contentTarget.addEventListener('transitionend', this.onContentTransitionEnd)
      }

      open() {
        clearTimeout(this.closeTimeout)

        if (this.isOpen) return
        this.isOpen = true

        this.emit('dropdown:open', { bubbles: true, detail: { dropdown: this } })

        this.element.classList.add(this.elementOpenClass, this.elementTransitioningClass)
        this.toggleTarget.setAttribute('aria-expanded', 'true')

        window.addEventListener('click', this.onClick)
        window.addEventListener('keydown', this.onKeydown)

        this.emit('mobile-nav:close', null, window)
      }

      close() {
        if (!this.isOpen) return
        this.isOpen = false

        this.emit('dropdown:close', { bubbles: true, detail: { dropdown: this } })

        this.element.classList.add(this.elementTransitioningClass)
        this.element.classList.remove(this.elementOpenClass)
        this.toggleTarget.setAttribute('aria-expanded', 'false')

        window.removeEventListener('click', this.onClick)
        window.removeEventListener('keydown', this.onKeydown)
      }

      toggle(ev) {
        if (ev) {
          ev.preventDefault()
        }

        if (this.isOpen) {
          this.close()
        } else {
          this.open()
        }
      }

      onClick(ev) {
        if (
          !this.contentTarget.contains(ev.target) &&
          !this.toggleTarget.contains(ev.target)
        ) {
          this.close()
        }
      }

      onElementKeydown(ev) {
        const up = ev.key === 'ArrowUp'
        const down = ev.key === 'ArrowDown'

        if (!up && !down) {
          return
        }

        // Prevent default arrow action of scrolling the page.
        ev.preventDefault()

        // Switch focus to next/previous focusable element.
        const index = this.focusables.indexOf(ev.target)
        const { length } = this.focusables
        const nextFocusable = this.focusables[(index + (down ? 1 : -1) + length) % length]

        if (nextFocusable) {
          const focus = () => {
            nextFocusable.focus()
          }

          if (this.isOpen) {
            focus()
          } else {
            this.open()
            setTimeout(focus, 100)
          }
        }
      }

      onKeydown(ev) {
        if (ev.key === 'Escape') {
          this.close()
        }
      }

      onContentTransitionEnd(ev) {
        if (ev.target === this.contentTarget) {
          this.element.classList.remove(this.elementTransitioningClass)
        }
      }

      emit(name, options, element = this.element) {
        element.dispatchEvent(new CustomEvent(name, {
          bubbles: false,
          cancelable: false,
          detail: null,
          ...options,
        }))
      }
    }
  );

  Stimulus.register(
    'page-nav',
    class extends Controller {
      static targets = ['link']

      initialize() {
        this.checkIntersection = this.checkIntersection.bind(this)
        this.links = {}
        this.titles = []

        const observer = new IntersectionObserver(this.checkIntersection)

        this.linkTargets.forEach((link) => {
          const id = link.hash.replace('#', '')
          const title = document.getElementById(id)
          this.links[id] = link
          observer.observe(title)
          this.titles.push(title)
        })
      }

      setCurrentLink(link) {
        if (this.currentLink) {
          if (link === this.currentLink) return

          this.unsetCurrentLink(this.currentLink)
        }

        this.currentLink = link
        this.currentLink.classList.add('is-current')
      }

      unsetCurrentLink(link) {
        link.classList.remove('is-current')
      }

      checkIntersection(entries) {
        for (const entry of entries) {
          entry.target.dataset.visibleStatus = entry.isIntersecting ? 'visible' : 'hidden'
        }

        for (const title of this.titles) {
          if (title.dataset.visibleStatus === 'visible') {
            this.setCurrentLink(this.links[title.id])
            break
          }
        }
      }
    }
  );

  Stimulus.register(
    'modal-link',
    class extends Controller {
      initialize() {
        this.open = this.open.bind(this)
        this.id ||= this.data.get('id')
      }

      open(ev) {
        if (ev) {
          ev.preventDefault()
        }

        this.modalTarget = Modal.open(this.id)
      }
    }
  );

  let _scrollbarWidth
  const scrollbarWidth = () => {
    if (_scrollbarWidth == null) {
      _scrollbarWidth = window.innerWidth - document.body.offsetWidth
    }

    return _scrollbarWidth
  }

  const disableBodyScroll = () => {
    const bodyScrollbarWidth = scrollbarWidth()

    if (bodyScrollbarWidth) {
      document.documentElement.style.setProperty('--modal-scrollbar-width', `${bodyScrollbarWidth}px`)
    }

    document.body.style.overflow = 'hidden'
    document.body.style.paddingRight = `${bodyScrollbarWidth}px`
  }

  const enableBodyScroll = () => {
    document.body.style.overflow = ''
    document.body.style.paddingRight = ''
    document.documentElement.style.removeProperty('--modal-scrollbar-width')
  }

  class Modal extends Controller {
    static targets = ['inner']

    static values = {
      // Open modal when created & initialized
      openOnCreate: Boolean,

      // Allow interaction with the page behind the modal
      allowInteraction: Boolean,
    }

    static options = {
      onClose: null,
    }

    initialize() {
      this.onDialogHide = this.onDialogHide.bind(this)
      this.onElementClick = this.onElementClick.bind(this)
      this.onKeydown = this.onKeydown.bind(this)

      this.openClass = 'is-open'
      this.dialog = new A11yDialog(this.element)

      // Store this modal so it can be reopened if a modal-link with the same ID is clicked
      this.id = this.data.get('id')
      Modal.instances[this.id] = this

      if (this.openOnCreateValue) {
        this.open()
      }
    }

    destroy() {
      if (this.isOpen) {
        this.close()
      }

      delete Modal.instances[this.id]

      this.element.parentNode.removeChild(this.element)
    }

    open() {
      if (this.isOpen) return
      this.isOpen = true

      requestAnimationFrame(() => {
        this.element.classList.add(this.openClass)
      })

      this.dialog.show()
      this.dialog.on('hide', this.onDialogHide)

      if (this.allowInteractionValue) {
        this.removeFocusTrap()
      } else {
        disableBodyScroll()
      }

      this.element.addEventListener('click', this.onElementClick)
      this.innerTarget.addEventListener('click', this.onInnerClick)

      document.addEventListener('keydown', this.onKeydown)

      // Remove a11y-dialog's keydown listener so we can control which modal closes when multiple are open
      document.removeEventListener('keydown', this.dialog._bindKeypress)

      setTimeout(() => {
        const autofocus = this.innerTarget.querySelector('[autofocus]')
        if (autofocus) {
          autofocus.focus()
        }
      }, 50)

      Modal.openInstances.push(this)

      // Make sure this modal is on top of all other modals
      if (Modal.zIndex) {
        Modal.zIndex += 1
        this.element.style.zIndex = Modal.zIndex
      } else {
        Modal.zIndex = Number(getComputedStyle(this.element).zIndex)
      }
    }

    close() {
      this.dialog.hide()
    }

    onDialogHide() {
      if (!this.isOpen) return
      this.isOpen = false

      // Add class to trigger hiding transition
      this.element.classList.remove(this.openClass)
      this.dialog.off('hide', this.onDialogHide)

      this.element.removeEventListener('click', this.onElementClick)
      this.innerTarget.removeEventListener('click', this.onInnerClick)

      document.removeEventListener('keydown', this.onKeydown)

      if (!this.allowInteractionValue) {
        enableBodyScroll()
      }

      // If modal has `data-modal-destroy-on-close` attribute
      if (this.data.get('destroy-on-close') != null) {
        // Wait until transition ends before removing modal element from DOM
        setTimeout(this.destroy.bind(this), 350)
      }

      const index = Modal.openInstances.indexOf(this)
      if (index > -1) {
        Modal.openInstances.splice(index, 1)
      }
    }

    onElementClick(ev) {
      ev.preventDefault()
      this.close()
    }

    onInnerClick(ev) {
      // Prevent click reaching this.element and closing modal
      ev.stopPropagation()
    }

    onKeydown(ev) {
      if (ev.key === 'Escape') {
        // Only close modal if this is the top-most instance
        if (Modal.openInstances.indexOf(this) === Modal.openInstances.length - 1) {
          ev.preventDefault()
          ev.stopImmediatePropagation()

          this.close()
        }
      }
    }

    // Remove the focus trap set by a11y-dialog, allowing interaction with elements outside the modal
    removeFocusTrap() {
      this.dialog._previouslyFocused = null
      document.body.removeEventListener('focus', this.dialog._maintainFocus, true)
      document.removeEventListener('keydown', this.dialog._bindKeypress)
    }
  }

  Modal.get = (id) => Modal.instances[id] || null

  Modal.open = (id) => {
    let modalTarget

    const modal = Modal.get(id)
    if (modal) {
      modal.open()
      modalTarget = modal.element
    } else {
      modalTarget = Modal.create(id, { openOnCreate: true })
    }

    return modalTarget
  }

  Modal.close = (id) => {
    // If called without id param, close all open modals
    if (!id) {
      Modal.openInstances.forEach((modal) => {
        modal.close()
      })

      return
    }

    const modal = Modal.get(id)
    if (modal) {
      modal.close()
    }
  }

  Modal.create = (id, { openOnCreate = false, enableScroll = false } = {}) => {
    const modal = Modal.get(id)
    if (modal) {
      return modal.element
    }

    let modalTarget = document.querySelector(`[data-modal-id="${id}"]`)

    if (!modalTarget) {
      const template = document.getElementById(id)

      if (!template) {
        return false
      }

      modalTarget = document.importNode(template.content, true).firstElementChild
    }

    if (modalTarget.dataset.modalOpenOnCreateValue == null) {
      modalTarget.dataset.modalOpenOnCreateValue = openOnCreate
    }

    if (modalTarget.dataset.modalEnableScrollValue == null) {
      modalTarget.dataset.modalEnableScrollValue = enableScroll
    }

    // Modals open automatically when Stimulus finds them in the DOM
    document.body.appendChild(modalTarget)

    // Scale SVGs added to DOM for IE11
    if (window.scaleSvgs) {
      window.scaleSvgs(modalTarget)
    }

    // Polyfill picture and srcset in new content
    if (window.picturefill) {
      window.picturefill()
    }

    return modalTarget
  }

  // Check if a modal is open by ID
  Modal.isOpen = (id) => {
    return Modal.openInstances.some((modal) => modal.id === id)
  }

  Modal.instances = {}

  Modal.openInstances = []

  Stimulus.register('modal', Modal);
})();
