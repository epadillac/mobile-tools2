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
    "copyBtn",
    "divideModal",
    "divideItemName",
    "divideItemPrice",
    "divideNInput"
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

    // Item dividing
    this.dividingItemRow = null

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
    const dividedItems = {}

    this.itemsContainerTarget.querySelectorAll('[data-item-id]').forEach(row => {
      const itemId = row.dataset.itemId
      const assignedTo = row.dataset.assignedTo

      // Save assignments
      if (assignedTo) {
        assignments[itemId] = assignedTo
      }

      // Track divided items (headers and their sub-items)
      if (row.dataset.isDividedHeader === 'true') {
        const group = row.dataset.group
        const nameEl = row.querySelector('.truncate')
        const itemName = nameEl ? nameEl.textContent.replace(' (dividido)', '').trim() : 'Articulo'

        dividedItems[itemId] = {
          originalItemId: itemId,
          group: group,
          itemName: itemName,
          subItems: []
        }
      }

      // Track divided sub-items (they start with 'divided_')
      if (itemId.startsWith('divided_')) {
        const group = row.dataset.group
        const price = parseFloat(row.dataset.price) || 0

        // Find the parent divided item by group
        const parentRow = this.itemsContainerTarget.querySelector(`[data-group="${group}"][data-is-divided-header="true"]`)
        if (parentRow) {
          const parentId = parentRow.dataset.itemId
          if (!dividedItems[parentId]) {
            const nameEl = parentRow.querySelector('.truncate')
            const itemName = nameEl ? nameEl.textContent.replace(' (dividido)', '').trim() : 'Articulo'
            dividedItems[parentId] = {
              originalItemId: parentId,
              group: group,
              itemName: itemName,
              subItems: []
            }
          }
          dividedItems[parentId].subItems.push({
            subItemId: itemId,
            price: price,
            assignedTo: assignedTo || ''
          })
        }
      }
    })

    const state = {
      people: this.people,
      selectedPersonId: this.selectedPersonId,
      nextPersonId: this.nextPersonId,
      assignments: assignments,
      dividedItems: dividedItems,
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

      // Restore divided items FIRST (before assignments)
      if (state.dividedItems) {
        Object.values(state.dividedItems).forEach(divided => {
          const originalRow = this.itemsContainerTarget.querySelector(`[data-item-id="${divided.originalItemId}"]`)
          if (originalRow && divided.subItems && divided.subItems.length > 0) {
            // Convert to header
            this.convertToHeaderRow(originalRow, divided.itemName)

            // Find the header row again (it was replaced by cloning)
            const headerRow = this.itemsContainerTarget.querySelector(`[data-item-id="${divided.originalItemId}"]`)

            // Create sub-items
            let insertAfter = headerRow
            divided.subItems.forEach((subItem, index) => {
              const assignedPersonId = subItem.assignedTo ? parseInt(subItem.assignedTo) : null
              const subRow = this.createDividedSubRowWithId(
                divided.itemName,
                subItem.price,
                divided.group,
                assignedPersonId,
                subItem.subItemId
              )
              insertAfter.after(subRow)
              insertAfter = subRow
            })
          }
        })
      }

      // Restore assignments for non-divided items
      if (state.assignments) {
        this.itemsContainerTarget.querySelectorAll('[data-item-id]').forEach(row => {
          const itemId = row.dataset.itemId
          // Skip divided sub-items (already handled above) and headers
          if (itemId.startsWith('divided_') || row.dataset.isDividedHeader === 'true') {
            return
          }

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

  // Create a divided sub-item with a specific ID (for restoring state)
  createDividedSubRowWithId(itemName, price, group, assignedToPersonId, specificItemId) {
    const div = document.createElement('div')
    div.className = 'cursor-pointer py-1 px-2 -mx-2 rounded transition-all border-l-4'
    div.style.borderLeftColor = 'transparent'
    div.dataset.itemId = specificItemId
    div.dataset.isModifier = 'true'
    div.dataset.group = group
    div.dataset.price = price.toFixed(2)
    div.dataset.assignedTo = ''

    // If assigned to a person, set the color
    if (assignedToPersonId !== null) {
      const person = this.people.find(p => p.id === assignedToPersonId)
      if (person) {
        const color = this.colors[person.colorIndex % this.colors.length]
        div.dataset.assignedTo = String(assignedToPersonId)
        div.style.borderLeftColor = color.hex
        div.style.backgroundColor = color.hex + '10'
      }
    }

    // Style like a modifier (nested, with ÷ prefix to indicate divided)
    div.innerHTML = `
      <div class="flex justify-between items-center text-gray-500 text-xs pl-3">
        <span class="truncate">÷ ${itemName}</span>
        <span class="ml-2 whitespace-nowrap">$${price.toFixed(2)}</span>
      </div>
    `

    // Add click handler
    div.addEventListener('click', (e) => {
      e.stopPropagation()
      this.assignItemToPerson(div, this.selectedPersonId)
    })

    return div
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
    // Ignore clicks on divide button
    if (e.target.closest('.divide-btn')) {
      return
    }

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

  // Handle divide button click
  handleDivideClick(e) {
    e.stopPropagation() // Prevent row click
    const row = e.target.closest('[data-item-id]')
    if (row) {
      this.openDivideModal(row)
    }
  }

  // Divide Modal Management
  openDivideModal(row) {
    // Only allow dividing main items (not modifiers)
    if (row.dataset.isModifier === 'true') {
      return
    }

    this.dividingItemRow = row
    const price = parseFloat(row.dataset.price) || 0
    const nameEl = row.querySelector('.truncate')
    const itemName = nameEl ? nameEl.textContent.trim() : 'Articulo'

    this.divideItemNameTarget.textContent = itemName
    this.divideItemPriceTarget.textContent = `$${price.toFixed(2)}`

    this.divideModalTarget.classList.remove('hidden')
    this.divideModalTarget.classList.add('flex')
  }

  closeDivideModal() {
    this.divideModalTarget.classList.add('hidden')
    this.divideModalTarget.classList.remove('flex')
    this.dividingItemRow = null
  }

  closeDivideModalOnOutsideClick(e) {
    if (e.target === this.divideModalTarget) {
      this.closeDivideModal()
    }
  }

  // Divide equally among all people
  divideEqually() {
    if (!this.dividingItemRow) return

    const price = parseFloat(this.dividingItemRow.dataset.price) || 0
    const numPeople = this.people.length
    const pricePerPerson = price / numPeople
    const group = this.dividingItemRow.dataset.group
    const nameEl = this.dividingItemRow.querySelector('.truncate')
    const itemName = nameEl ? nameEl.textContent.trim() : 'Articulo'

    // Convert main item to header (no price, not clickable for assignment)
    this.convertToHeaderRow(this.dividingItemRow, itemName)

    // Insert sub-items after the header
    let insertAfter = this.dividingItemRow
    this.people.forEach((person, index) => {
      const subRow = this.createDividedSubRow(itemName, pricePerPerson, group, person.id, index)
      insertAfter.after(subRow)
      insertAfter = subRow
    })

    this.closeDivideModal()
    this.updateSplitSummary()
  }

  // Divide into 2 parts
  divideByTwo() {
    this.divideIntoN(2)
  }

  // Divide into N parts
  divideByN() {
    const n = parseInt(this.divideNInputTarget.value) || 3
    this.divideIntoN(n)
  }

  divideIntoN(n) {
    if (!this.dividingItemRow || n < 2) return

    const price = parseFloat(this.dividingItemRow.dataset.price) || 0
    const pricePerPart = price / n
    const group = this.dividingItemRow.dataset.group
    const nameEl = this.dividingItemRow.querySelector('.truncate')
    const itemName = nameEl ? nameEl.textContent.trim() : 'Articulo'

    // Convert main item to header (no price, not clickable for assignment)
    this.convertToHeaderRow(this.dividingItemRow, itemName)

    // Insert sub-items after the header
    let insertAfter = this.dividingItemRow
    for (let i = 0; i < n; i++) {
      const subRow = this.createDividedSubRow(itemName, pricePerPart, group, null, i)
      insertAfter.after(subRow)
      insertAfter = subRow
    }

    this.closeDivideModal()
    this.updateSplitSummary()
  }

  // Convert the main item row into a non-clickable header
  convertToHeaderRow(row, itemName, originalPrice = null) {
    // Store original price for undivide
    const priceToStore = originalPrice || parseFloat(row.dataset.price) || 0
    row.dataset.originalPrice = priceToStore.toString()
    row.dataset.price = '0'
    row.dataset.assignedTo = ''
    row.dataset.isDividedHeader = 'true'
    row.dataset.originalName = itemName
    row.style.borderLeftColor = 'transparent'
    row.style.backgroundColor = ''
    row.classList.remove('cursor-pointer')
    row.classList.add('cursor-default')

    // Update the display to show it's a divided item header with undivide button
    row.innerHTML = `
      <div class="flex justify-between items-center text-gray-600 text-sm">
        <span class="truncate font-medium">${itemName} <span class="text-xs text-gray-400">(dividido)</span></span>
        <div class="flex items-center gap-2 ml-2">
          <button type="button"
                  class="undivide-btn p-1 text-gray-400 hover:text-red-500 hover:bg-red-50 rounded transition-colors"
                  title="Deshacer division">
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"></path>
            </svg>
          </button>
          <span class="whitespace-nowrap text-gray-400">-</span>
        </div>
      </div>
    `

    // Remove click event by cloning the node
    const newRow = row.cloneNode(true)
    row.parentNode.replaceChild(newRow, row)
    this.dividingItemRow = newRow

    // Add click handler for undivide button
    const undivideBtn = newRow.querySelector('.undivide-btn')
    if (undivideBtn) {
      undivideBtn.addEventListener('click', (e) => {
        e.stopPropagation()
        this.undivideItem(newRow)
      })
    }
  }

  // Restore a divided item back to its original state
  undivideItem(headerRow) {
    const group = headerRow.dataset.group
    const originalPrice = parseFloat(headerRow.dataset.originalPrice) || 0
    const originalName = headerRow.dataset.originalName || 'Articulo'

    // Remove all divided sub-items for this group
    const subItems = this.itemsContainerTarget.querySelectorAll(`[data-item-id^="divided_"][data-group="${group}"]`)
    subItems.forEach(subItem => subItem.remove())

    // Restore the header row to a normal item
    headerRow.dataset.price = originalPrice.toString()
    headerRow.dataset.assignedTo = ''
    delete headerRow.dataset.isDividedHeader
    delete headerRow.dataset.originalPrice
    delete headerRow.dataset.originalName
    // Remove the broken Stimulus action attribute (it doesn't work after cloning)
    delete headerRow.dataset.action
    headerRow.classList.remove('cursor-default')
    headerRow.classList.add('cursor-pointer')

    // Restore the original item display with divide button
    headerRow.innerHTML = `
      <div class="flex justify-between items-center text-gray-800 text-sm">
        <span class="truncate font-medium">${originalName}</span>
        <div class="flex items-center gap-2 ml-2">
          <button type="button"
                  class="divide-btn p-1 text-gray-400 hover:text-indigo-600 hover:bg-indigo-50 rounded transition-colors"
                  title="Dividir articulo">
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 7h12m0 0l-4-4m4 4l-4 4m0 6H4m0 0l4 4m-4-4l4-4"></path>
            </svg>
          </button>
          <span class="whitespace-nowrap font-bold">$${originalPrice.toFixed(2)}</span>
        </div>
      </div>
    `

    // Add click handler for the row (main item assignment)
    headerRow.addEventListener('click', (e) => {
      // Ignore clicks on divide button
      if (e.target.closest('.divide-btn')) {
        return
      }

      // Main item - assign all items in group
      const groupRows = this.getGroupRows(group)
      const currentAssigned = headerRow.dataset.assignedTo
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

      this.updateSplitSummary()
    })

    // Add click handler for divide button
    const divideBtn = headerRow.querySelector('.divide-btn')
    if (divideBtn) {
      divideBtn.addEventListener('click', (e) => {
        e.stopPropagation()
        this.openDivideModal(headerRow)
      })
    }

    this.updateSplitSummary()
  }

  // Create a nested sub-item row (modifier style)
  createDividedSubRow(itemName, price, group, assignedToPersonId, partIndex) {
    const newItemId = `divided_${Date.now()}_${partIndex}`

    const div = document.createElement('div')
    div.className = 'cursor-pointer py-1 px-2 -mx-2 rounded transition-all border-l-4'
    div.style.borderLeftColor = 'transparent'
    div.dataset.itemId = newItemId
    div.dataset.isModifier = 'true'  // Treat as modifier for individual assignment
    div.dataset.group = group  // Same group as parent
    div.dataset.price = price.toFixed(2)
    div.dataset.assignedTo = ''

    // If assigned to a person, set the color
    if (assignedToPersonId !== null) {
      const person = this.people.find(p => p.id === assignedToPersonId)
      if (person) {
        const color = this.colors[person.colorIndex % this.colors.length]
        div.dataset.assignedTo = String(assignedToPersonId)
        div.style.borderLeftColor = color.hex
        div.style.backgroundColor = color.hex + '10'
      }
    }

    // Style like a modifier (nested, with ÷ prefix to indicate divided)
    div.innerHTML = `
      <div class="flex justify-between items-center text-gray-500 text-xs pl-3">
        <span class="truncate">÷ ${itemName}</span>
        <span class="ml-2 whitespace-nowrap">$${price.toFixed(2)}</span>
      </div>
    `

    // Add click handler directly (Stimulus doesn't auto-bind dynamically created elements)
    div.addEventListener('click', (e) => {
      e.stopPropagation()
      this.assignItemToPerson(div, this.selectedPersonId)
    })

    return div
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

    // Initialize totals for all people (use string keys for consistency with dataset)
    this.people.forEach(p => {
      totals[String(p.id)] = 0
    })

    // Calculate totals from all items including dynamically created divided sub-items
    rows.forEach(row => {
      const assignedTo = row.dataset.assignedTo
      const price = parseFloat(row.dataset.price) || 0

      if (assignedTo && assignedTo in totals) {
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
      const subtotal = totals[String(person.id)] || 0
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

  // Detailed WhatsApp Text Generation (with items per person)
  generateDetailedWhatsAppText() {
    const tipPercent = this.getTipPercentage()
    const rows = Array.from(this.itemsContainerTarget.querySelectorAll('[data-item-id]'))

    // Circle emojis matching color palette
    const circleEmojis = ['🔵', '🟢', '🟡', '🟣', '🔴', '🩵', '🩷', '🔷']

    // Helper to format currency with padding
    const formatMoney = (amount) => {
      return '$' + amount.toFixed(2).padStart(7)
    }

    let grandSubtotal = 0
    let grandTotal = 0

    // Build the text
    let text = '🧾 *División de Cuenta - Detalle*\n'
    text += '```\n'

    this.people.forEach((person) => {
      const emoji = circleEmojis[person.colorIndex % circleEmojis.length]
      const personItems = []
      let personSubtotal = 0

      // Find all items assigned to this person
      rows.forEach(row => {
        if (row.dataset.assignedTo === String(person.id)) {
          const price = parseFloat(row.dataset.price) || 0
          if (price > 0) {
            // Get item name from the row
            const nameEl = row.querySelector('.truncate')
            let itemName = nameEl ? nameEl.textContent.trim() : 'Articulo'
            // Clean up the name (remove ÷ prefix if present)
            itemName = itemName.replace(/^[÷+]\s*/, '')
            personItems.push({ name: itemName, price: price })
            personSubtotal += price
          }
        }
      })

      const personTip = personSubtotal * tipPercent
      const personTotal = personSubtotal + personTip
      grandSubtotal += personSubtotal
      grandTotal += personTotal

      text += '------------------------------\n'
      text += `${emoji} ${person.name}\n`

      // List items
      if (personItems.length > 0) {
        personItems.forEach(item => {
          const truncatedName = item.name.length > 18 ? item.name.substring(0, 18) + '...' : item.name
          text += `  • ${truncatedName.padEnd(18)} ${formatMoney(item.price)}\n`
        })
        text += `  ────────────────────────\n`
      }

      text += `  Subtotal:            ${formatMoney(personSubtotal)}\n`
      if (tipPercent > 0) {
        text += `  Propina (${(tipPercent * 100).toFixed(0)}%):      ${formatMoney(personTip)}\n`
      }
      text += `  TOTAL:               ${formatMoney(personTotal)}\n`
    })

    text += '------------------------------\n'
    if (tipPercent > 0) {
      text += `Subtotal:              ${formatMoney(grandSubtotal)}\n`
      text += `Propina (${(tipPercent * 100).toFixed(0)}%):        ${formatMoney(grandTotal - grandSubtotal)}\n`
    }
    text += `💰 TOTAL:              ${formatMoney(grandTotal)}\n`
    text += '```'

    return text
  }

  // WhatsApp Text Generation
  generateWhatsAppText() {
    const tipPercent = this.getTipPercentage()
    const totals = {}

    // Initialize totals for all people (use string keys for consistency with dataset)
    this.people.forEach(p => { totals[String(p.id)] = 0 })

    // Calculate totals from all items including dynamically created divided sub-items
    this.itemsContainerTarget.querySelectorAll('[data-item-id]').forEach(row => {
      const assignedTo = row.dataset.assignedTo
      const price = parseFloat(row.dataset.price) || 0
      if (assignedTo && assignedTo in totals) {
        totals[assignedTo] += price
      }
    })

    // Circle emojis matching color palette
    const circleEmojis = ['🔵', '🟢', '🟡', '🟣', '🔴', '🩵', '🩷', '🔷']

    let grandSubtotal = 0
    let grandTotal = 0

    // Helper to format currency with padding
    const formatMoney = (amount) => {
      return '$' + amount.toFixed(2).padStart(7)
    }

    // Build the monospace section
    let mono = ''
    mono += '------------------------------\n'

    this.people.forEach((person) => {
      const subtotal = totals[String(person.id)] || 0
      const tip = subtotal * tipPercent
      const total = subtotal + tip
      grandSubtotal += subtotal
      grandTotal += total

      const emoji = circleEmojis[person.colorIndex % circleEmojis.length]

      mono += `${emoji} ${person.name}\n`
      if (tipPercent > 0) {
        mono += `   Consumo:       ${formatMoney(subtotal)}\n`
        mono += `   Propina:       ${formatMoney(tip)}\n`
      }
      mono += `   Total:         ${formatMoney(total)}\n`
      mono += '------------------------------\n'
    })

    if (tipPercent > 0) {
      mono += `   Subtotal:      ${formatMoney(grandSubtotal)}\n`
      mono += `   Propina (${(tipPercent * 100).toFixed(0)}%): ${formatMoney(grandTotal - grandSubtotal)}\n`
    }
    mono += `💰 TOTAL:         ${formatMoney(grandTotal)}\n`

    // Build final text with header outside monospace and content inside
    let text = '🧾 *División de Cuenta*'
    text += '```\n'
    text += mono
    text += '```'

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

  // Copy detailed summary with items per person
  async copyDetailedSummary(e) {
    const copyBtn = e.currentTarget
    const copyBtnText = copyBtn.querySelector('.copy-btn-text')
    const originalText = copyBtnText ? copyBtnText.textContent : ''

    const text = this.generateDetailedWhatsAppText()

    try {
      await navigator.clipboard.writeText(text)

      // Show success feedback (keep indigo color)
      if (copyBtnText) {
        copyBtnText.textContent = '\u00A1Copiado!'
      }

      // Reset after 2 seconds
      setTimeout(() => {
        if (copyBtnText) {
          copyBtnText.textContent = originalText
        }
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