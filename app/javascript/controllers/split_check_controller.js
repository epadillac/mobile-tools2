import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "peopleContainer",
    "itemsContainer",
    "splitSummary",
    "tipInput",
    "tipPreset",
    "tipDisplay",
    "nameModal",
    "nameInput",
    "copyBtn"
  ]

  static values = {
    storageKey: String
  }

  // Color palette for people
  colors = [
    { bg: 'bg-blue-500', border: 'border-blue-500', light: 'bg-blue-50', text: 'text-blue-700', hex: '#3b82f6' },
    { bg: 'bg-emerald-500', border: 'border-emerald-500', light: 'bg-emerald-50', text: 'text-emerald-700', hex: '#10b981' },
    { bg: 'bg-amber-500', border: 'border-amber-500', light: 'bg-amber-50', text: 'text-amber-700', hex: '#f59e0b' },
    { bg: 'bg-purple-500', border: 'border-purple-500', light: 'bg-purple-50', text: 'text-purple-700', hex: '#a855f7' },
    { bg: 'bg-rose-500', border: 'border-rose-500', light: 'bg-rose-50', text: 'text-rose-700', hex: '#f43f5e' },
    { bg: 'bg-cyan-500', border: 'border-cyan-500', light: 'bg-cyan-50', text: 'text-cyan-700', hex: '#06b6d4' },
    { bg: 'bg-pink-500', border: 'border-pink-500', light: 'bg-pink-50', text: 'text-pink-700', hex: '#ec4899' },
    { bg: 'bg-indigo-500', border: 'border-indigo-500', light: 'bg-indigo-50', text: 'text-indigo-700', hex: '#6366f1' }
  ]

  connect() {
    this.people = [
      { id: 1, name: 'Yo', colorIndex: 0 },
      { id: 2, name: 'Persona 1', colorIndex: 1 }
    ]
    this.selectedPersonId = 1
    this.nextPersonId = 3
    this.editingPersonId = null
    this.lastTapTime = {}
    this.doubleTapDelay = 300

    // Set storage key based on current path
    if (!this.hasStorageKeyValue) {
      this.storageKeyValue = 'splitCheck_' + window.location.pathname
    }

    this.loadState()
    this.renderPeople()
    this.updateSplitSummary()
  }

  // LocalStorage State Management
  saveState() {
    const assignments = {}
    this.itemsContainerTarget.querySelectorAll('[data-item-id]').forEach(row => {
      const itemId = row.dataset.itemId
      const assignedTo = row.dataset.assignedTo
      if (assignedTo) {
        assignments[itemId] = assignedTo
      }
    })

    const state = {
      people: this.people,
      selectedPersonId: this.selectedPersonId,
      nextPersonId: this.nextPersonId,
      assignments: assignments,
      tipPercentage: this.tipInputTarget.value
    }

    try {
      localStorage.setItem(this.storageKeyValue, JSON.stringify(state))
    } catch (e) {
      console.warn('Could not save state to localStorage:', e)
    }
  }

  loadState() {
    try {
      const saved = localStorage.getItem(this.storageKeyValue)
      if (!saved) return false

      const state = JSON.parse(saved)

      // Restore people
      if (state.people && Array.isArray(state.people) && state.people.length > 0) {
        this.people = state.people
      }

      // Restore selected person
      if (state.selectedPersonId) {
        this.selectedPersonId = state.selectedPersonId
        // Make sure selected person exists
        if (!this.people.find(p => p.id === this.selectedPersonId)) {
          this.selectedPersonId = this.people[0].id
        }
      }

      // Restore next person ID
      if (state.nextPersonId) {
        this.nextPersonId = state.nextPersonId
      }

      // Restore tip percentage
      if (state.tipPercentage !== undefined) {
        this.tipInputTarget.value = state.tipPercentage
      }

      // Restore assignments
      if (state.assignments) {
        this.itemsContainerTarget.querySelectorAll('[data-item-id]').forEach(row => {
          const itemId = row.dataset.itemId
          const assignedTo = state.assignments[itemId]
          if (assignedTo) {
            const person = this.people.find(p => p.id === parseInt(assignedTo))
            if (person) {
              const color = this.colors[person.colorIndex % this.colors.length]
              row.dataset.assignedTo = assignedTo
              row.style.borderLeftColor = color.hex
              row.style.backgroundColor = color.hex + '10'
            }
          }
        })
      }

      return true
    } catch (e) {
      console.warn('Could not load state from localStorage:', e)
      return false
    }
  }

  // Modal Management
  openNameModal(personId) {
    const person = this.people.find(p => p.id === personId)
    if (!person) return

    this.editingPersonId = personId
    this.nameInputTarget.value = person.name
    this.nameModalTarget.classList.remove('hidden')
    this.nameModalTarget.classList.add('flex')
    this.nameInputTarget.focus()
    this.nameInputTarget.select()
  }

  closeNameModal() {
    this.nameModalTarget.classList.add('hidden')
    this.nameModalTarget.classList.remove('flex')
    this.editingPersonId = null
    this.nameInputTarget.value = ''
  }

  saveName() {
    if (this.editingPersonId === null) return

    const newName = this.nameInputTarget.value.trim()
    if (newName) {
      const person = this.people.find(p => p.id === this.editingPersonId)
      if (person) {
        person.name = newName
        this.renderPeople()
        this.updateSplitSummary()
      }
    }
    this.closeNameModal()
  }

  handleNameKeydown(e) {
    if (e.key === 'Enter') {
      this.saveName()
    } else if (e.key === 'Escape') {
      this.closeNameModal()
    }
  }

  closeModalOnOutsideClick(e) {
    if (e.target === this.nameModalTarget) {
      this.closeNameModal()
    }
  }

  // Person Calculations
  getPersonTotal(personId) {
    let total = 0
    this.itemsContainerTarget.querySelectorAll('[data-item-id]').forEach(row => {
      if (row.dataset.assignedTo === String(personId)) {
        total += parseFloat(row.dataset.price) || 0
      }
    })
    return total
  }

  getUnassignedTotal() {
    let total = 0
    this.itemsContainerTarget.querySelectorAll('[data-item-id]').forEach(row => {
      if (!row.dataset.assignedTo) {
        total += parseFloat(row.dataset.price) || 0
      }
    })
    return total
  }

  getTipPercentage() {
    const value = parseFloat(this.tipInputTarget.value) || 0
    return Math.max(0, Math.min(100, value)) / 100
  }

  getNextAvailableColorIndex() {
    const usedColors = new Set(this.people.map(p => p.colorIndex))
    for (let i = 0; i < this.colors.length; i++) {
      if (!usedColors.has(i)) {
        return i
      }
    }
    // If all colors are used, find the least used one
    const colorCounts = {}
    this.people.forEach(p => {
      colorCounts[p.colorIndex] = (colorCounts[p.colorIndex] || 0) + 1
    })
    let minCount = Infinity
    let minIndex = 0
    for (let i = 0; i < this.colors.length; i++) {
      const count = colorCounts[i] || 0
      if (count < minCount) {
        minCount = count
        minIndex = i
      }
    }
    return minIndex
  }

  // People Management
  renderPeople() {
    this.peopleContainerTarget.innerHTML = ''

    const tipPercent = this.getTipPercentage()

    this.people.forEach(person => {
      const color = this.colors[person.colorIndex % this.colors.length]
      const isSelected = person.id === this.selectedPersonId
      const canDelete = this.people.length > 1
      const personSubtotal = this.getPersonTotal(person.id)
      const personTip = personSubtotal * tipPercent
      const personTotal = personSubtotal + personTip

      const btn = document.createElement('button')
      btn.className = `flex items-center gap-1 pl-3 ${canDelete ? 'pr-1' : 'pr-3'} py-1 rounded-full text-xs font-medium transition-all ${
        isSelected
          ? `${color.bg} text-white shadow-lg scale-105`
          : `bg-gray-100 text-gray-700 hover:bg-gray-200`
      }`
      btn.dataset.personId = person.id

      // Build display name with subtotal / total (with tip) if > 0
      let displayName = person.name
      if (personSubtotal > 0) {
        if (tipPercent > 0) {
          displayName = `${person.name} ($${personSubtotal.toFixed(0)} / $${personTotal.toFixed(0)})`
        } else {
          displayName = `${person.name} ($${personSubtotal.toFixed(0)})`
        }
      }

      // Build inner HTML with optional delete button
      let innerHtml = `
        <span class="w-3 h-3 rounded-full ${isSelected ? 'bg-white/50' : color.bg}"></span>
        <span>${displayName}</span>
      `

      if (canDelete) {
        innerHtml += `
          <span class="delete-btn w-5 h-5 flex items-center justify-center rounded-full ml-1 transition-all ${
            isSelected
              ? 'hover:bg-white/30 text-white/70 hover:text-white'
              : 'hover:bg-red-100 text-gray-400 hover:text-red-500'
          }" data-action="click->split-check#handleDeleteClick">
            <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"></path>
            </svg>
          </span>
        `
      }

      btn.innerHTML = innerHtml
      btn.addEventListener('click', (e) => this.handlePersonClick(e, person.id))

      this.peopleContainerTarget.appendChild(btn)
    })

    // Add "Add Person" button
    const addBtn = document.createElement('button')
    addBtn.className = 'flex items-center gap-1 px-3 py-1 rounded-full text-xs font-medium bg-gray-100 text-gray-500 hover:bg-gray-200 transition-all border border-dashed border-gray-300'
    addBtn.innerHTML = `
      <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 6v6m0 0v6m0-6h6m-6 0H6"></path>
      </svg>
      <span>Agregar</span>
    `
    addBtn.addEventListener('click', () => this.addPerson())
    this.peopleContainerTarget.appendChild(addBtn)

    // Add "Sin asignar" button if there are unassigned items
    const unassignedTotal = this.getUnassignedTotal()
    if (unassignedTotal > 0) {
      const unassignedBtn = document.createElement('button')
      unassignedBtn.className = 'flex items-center gap-1 px-3 py-1 rounded-full text-xs font-medium bg-gray-200 text-gray-500 border border-gray-300 hover:bg-gray-300 hover:border-gray-400 transition-all cursor-pointer'
      unassignedBtn.innerHTML = `
        <span>Restante ($${unassignedTotal.toFixed(0)})</span>
        <svg class="w-3 h-3 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 6v6m0 0v6m0-6h6m-6 0H6"></path>
        </svg>
      `
      unassignedBtn.title = 'Crear persona y asignar estos articulos'
      unassignedBtn.addEventListener('click', () => this.assignUnassignedToNewPerson())
      this.peopleContainerTarget.appendChild(unassignedBtn)
    }
  }

  assignUnassignedToNewPerson() {
    // Get all unassigned rows
    const unassignedRows = Array.from(this.itemsContainerTarget.querySelectorAll('[data-item-id]')).filter(row => !row.dataset.assignedTo)

    if (unassignedRows.length === 0) return

    // Create new person
    const colorIndex = this.getNextAvailableColorIndex()
    const newPersonId = this.nextPersonId
    this.people.push({
      id: newPersonId,
      name: `Persona ${newPersonId - 1}`,
      colorIndex: colorIndex
    })
    this.nextPersonId++

    // Assign all unassigned items to the new person
    const color = this.colors[colorIndex % this.colors.length]
    unassignedRows.forEach(row => {
      row.dataset.assignedTo = String(newPersonId)
      row.style.borderLeftColor = color.hex
      row.style.backgroundColor = color.hex + '10'
    })

    // Select the new person
    this.selectedPersonId = newPersonId

    this.renderPeople()
    this.updateSplitSummary()

    // Open modal to edit the name
    this.openNameModal(newPersonId)
  }

  handlePersonClick(e, personId) {
    // Check if delete button was clicked
    if (e.target.closest('.delete-btn')) {
      e.stopPropagation()
      this.deletePerson(personId)
      return
    }

    const now = Date.now()
    const lastTap = this.lastTapTime[personId] || 0

    if (now - lastTap < this.doubleTapDelay) {
      // Double tap detected - open edit modal
      e.preventDefault()
      this.openNameModal(personId)
      this.lastTapTime[personId] = 0
    } else {
      // Single tap - select person
      this.lastTapTime[personId] = now
      this.selectPerson(personId)
    }
  }

  selectPerson(personId) {
    this.selectedPersonId = personId
    this.renderPeople()
  }

  addPerson() {
    const colorIndex = this.getNextAvailableColorIndex()
    const newPersonId = this.nextPersonId
    this.people.push({
      id: newPersonId,
      name: `Persona ${newPersonId}`,
      colorIndex: colorIndex
    })
    this.selectedPersonId = newPersonId
    this.nextPersonId++
    this.renderPeople()
    this.updateSplitSummary()
    // Open modal to ask for the name
    this.openNameModal(newPersonId)
  }

  deletePerson(personId) {
    // Don't allow deleting if only one person left
    if (this.people.length <= 1) return

    // Unassign all rows assigned to this person
    const rows = this.itemsContainerTarget.querySelectorAll(`[data-assigned-to="${personId}"]`)
    rows.forEach(row => {
      row.dataset.assignedTo = ''
      row.style.borderLeftColor = 'transparent'
      row.style.backgroundColor = ''
    })

    // Remove person from array
    this.people = this.people.filter(p => p.id !== personId)

    // If deleted person was selected, select the first person
    if (this.selectedPersonId === personId) {
      this.selectedPersonId = this.people[0].id
    }

    this.renderPeople()
    this.updateSplitSummary()
  }

  handleDeleteClick(e) {
    e.stopPropagation()
    const personId = parseInt(e.target.closest('[data-person-id]').dataset.personId)
    this.deletePerson(personId)
  }

  // Item Assignment
  getGroupRows(group) {
    return Array.from(this.itemsContainerTarget.querySelectorAll(`[data-group="${group}"]`))
  }

  assignItemToPerson(row, personId) {
    const currentAssigned = row.dataset.assignedTo
    const person = this.people.find(p => p.id === personId)

    if (!person) return

    const color = this.colors[person.colorIndex % this.colors.length]

    // If already assigned to this person, unassign
    if (currentAssigned === String(personId)) {
      row.dataset.assignedTo = ''
      row.style.borderLeftColor = 'transparent'
      row.style.backgroundColor = ''
    } else {
      // Assign to person
      row.dataset.assignedTo = String(personId)
      row.style.borderLeftColor = color.hex
      row.style.backgroundColor = color.hex + '10' // 10% opacity
    }

    this.updateSplitSummary()
  }

  handleRowClick(e) {
    const row = e.currentTarget
    const isModifier = row.dataset.isModifier === 'true'
    const group = row.dataset.group

    if (!isModifier) {
      // Main item - assign all items in group
      const groupRows = this.getGroupRows(group)
      const currentAssigned = row.dataset.assignedTo
      const shouldAssign = currentAssigned !== String(this.selectedPersonId)

      groupRows.forEach(r => {
        if (shouldAssign) {
          this.assignItemToPerson(r, this.selectedPersonId)
        } else {
          // Unassign
          r.dataset.assignedTo = ''
          r.style.borderLeftColor = 'transparent'
          r.style.backgroundColor = ''
        }
      })
    } else {
      // Modifier - assign only this item
      this.assignItemToPerson(row, this.selectedPersonId)
    }

    this.updateSplitSummary()
  }

  // Tip Management
  updateTipPresetStyles() {
    const currentTip = this.tipInputTarget.value
    this.tipPresetTargets.forEach(btn => {
      if (btn.dataset.tip === currentTip) {
        btn.classList.remove('bg-gray-200', 'text-gray-700', 'hover:bg-gray-300', 'border-transparent')
        btn.classList.add('bg-indigo-600', 'text-white', 'border-indigo-600')
      } else {
        btn.classList.remove('bg-indigo-600', 'text-white', 'border-indigo-600')
        btn.classList.add('bg-gray-200', 'text-gray-700', 'hover:bg-gray-300', 'border-transparent')
      }
    })

    // Update the collapsed tip display
    if (this.hasTipDisplayTarget) {
      this.tipDisplayTarget.textContent = `${currentTip}%`
    }
  }

  handleTipChange() {
    this.updateSplitSummary()
  }

  setTipPreset(e) {
    this.tipInputTarget.value = e.currentTarget.dataset.tip
    this.updateSplitSummary()
  }

  // Split Summary
  updateSplitSummary() {
    const rows = this.itemsContainerTarget.querySelectorAll('[data-item-id]')
    const totals = {}
    const tipPercent = this.getTipPercentage()

    // Initialize totals for all people
    this.people.forEach(p => {
      totals[p.id] = 0
    })

    // Calculate totals
    rows.forEach(row => {
      const assignedTo = row.dataset.assignedTo
      const price = parseFloat(row.dataset.price) || 0

      if (assignedTo && totals[assignedTo] !== undefined) {
        totals[assignedTo] += price
      }
    })

    // Calculate unassigned
    let unassignedTotal = 0
    rows.forEach(row => {
      if (!row.dataset.assignedTo) {
        unassignedTotal += parseFloat(row.dataset.price) || 0
      }
    })

    // Render summary
    this.splitSummaryTarget.innerHTML = ''

    this.people.forEach(person => {
      const color = this.colors[person.colorIndex % this.colors.length]
      const subtotal = totals[person.id]
      const tip = subtotal * tipPercent
      const total = subtotal + tip

      const div = document.createElement('div')
      div.className = `flex items-center justify-between p-4 rounded-lg ${color.light} border-l-4 ${color.border}`
      div.innerHTML = `
        <div class="flex items-center gap-3">
          <span class="w-4 h-4 rounded-full ${color.bg}"></span>
          <span class="font-medium ${color.text}">${person.name}</span>
        </div>
        <div class="text-right">
          <p class="text-sm text-gray-500">Subtotal: $${subtotal.toFixed(2)}</p>
          ${tipPercent > 0 ? `<p class="text-sm text-gray-500">Propina (${(tipPercent * 100).toFixed(0)}%): $${tip.toFixed(2)}</p>` : ''}
          <p class="font-bold ${color.text} text-lg">$${total.toFixed(2)}</p>
        </div>
      `
      this.splitSummaryTarget.appendChild(div)
    })

    // Show unassigned if any (no tip applied to unassigned items)
    if (unassignedTotal > 0) {
      const div = document.createElement('div')
      div.className = 'flex items-center justify-between p-4 rounded-lg bg-gray-100 border-l-4 border-gray-400'
      div.innerHTML = `
        <div class="flex items-center gap-3">
          <span class="w-4 h-4 rounded-full bg-gray-400"></span>
          <span class="font-medium text-gray-600">Sin asignar</span>
        </div>
        <div class="text-right">
          <p class="font-bold text-gray-600 text-lg">$${unassignedTotal.toFixed(2)}</p>
        </div>
      `
      this.splitSummaryTarget.appendChild(div)
    }

    this.updateTipPresetStyles()

    // Update people buttons to show new totals
    this.renderPeople()

    // Save state after each update
    this.saveState()
  }

  // WhatsApp Text Generation
  generateWhatsAppText() {
    const tipPercent = this.getTipPercentage()
    const rows = this.itemsContainerTarget.querySelectorAll('[data-item-id]')
    const totals = {}

    // Calculate totals
    this.people.forEach(p => { totals[p.id] = 0 })
    rows.forEach(row => {
      const assignedTo = row.dataset.assignedTo
      const price = parseFloat(row.dataset.price) || 0
      if (assignedTo && totals[assignedTo] !== undefined) {
        totals[assignedTo] += price
      }
    })

    // Build formatted text
    let text = '\u{1F9FE} *Division de Cuenta*\n'
    text += '\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\n\n'

    let grandSubtotal = 0
    let grandTotal = 0

    // Helper to pad amounts for alignment
    const padAmount = (amount) => {
      return amount.toFixed(2).padStart(8)
    }

    this.people.forEach(person => {
      const subtotal = totals[person.id]
      const tip = subtotal * tipPercent
      const total = subtotal + tip
      grandSubtotal += subtotal
      grandTotal += total

      const tipLabel = `Propina (${(tipPercent * 100).toFixed(0)}%)`

      text += `\u{1F464} *${person.name}*\n`
      text += `   Consumo:       $${padAmount(subtotal)}\n`
      if (tipPercent > 0) {
        text += `   ${tipLabel.padEnd(13)}: $${padAmount(tip)}\n`
      }
      text += `   *Total:        $${padAmount(total)}*\n\n`
    })

    text += '\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\u2501\n'
    if (tipPercent > 0) {
      text += `\u{1F4B0} *Total:   $${padAmount(grandSubtotal)}*\n`
      text += `\u{1F4B0} *Con ${(tipPercent * 100).toFixed(0)}% de propina: $${padAmount(grandTotal)}*`
    } else {
      text += `\u{1F4B0} *Total:   $${padAmount(grandTotal)}*`
    }

    return text
  }

  // Clipboard
  async copySummary(e) {
    const copyBtn = e.currentTarget
    const copyBtnText = copyBtn.querySelector('.copy-btn-text')
    const originalText = copyBtnText ? copyBtnText.textContent : ''

    const text = this.generateWhatsAppText()

    try {
      await navigator.clipboard.writeText(text)

      // Show success feedback
      if (copyBtnText) {
        copyBtnText.textContent = '\u00A1Copiado!'
      }
      copyBtn.classList.remove('bg-green-500', 'hover:bg-green-600')
      copyBtn.classList.add('bg-emerald-600')

      // Reset after 2 seconds
      setTimeout(() => {
        if (copyBtnText) {
          copyBtnText.textContent = originalText
        }
        copyBtn.classList.remove('bg-emerald-600')
        copyBtn.classList.add('bg-green-500', 'hover:bg-green-600')
      }, 2000)
    } catch (err) {
      console.error('Failed to copy:', err)
      if (copyBtnText) {
        copyBtnText.textContent = 'Error'
        setTimeout(() => {
          copyBtnText.textContent = originalText
        }, 2000)
      }
    }
  }
}