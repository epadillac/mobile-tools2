import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "dropZone",
    "fileInput",
    "cameraInput",
    "cameraSection",
    "dragText",
    "uploadContent",
    "imagePreview",
    "previewImg",
    "fileName",
    "submitBtn",
    "submitText",
    "submitLoading"
  ]

  connect() {
    this.clearSplitCheckData()
    this.setupMobileDetection()
    this.setupDragAndDrop()
  }

  clearSplitCheckData() {
    const keysToRemove = []
    for (let i = 0; i < localStorage.length; i++) {
      const key = localStorage.key(i)
      if (key && key.startsWith('splitCheck_')) {
        keysToRemove.push(key)
      }
    }
    keysToRemove.forEach(key => localStorage.removeItem(key))
  }

  isMobileDevice() {
    return /Android|webOS|iPhone|iPad|iPod|BlackBerry|IEMobile|Opera Mini/i.test(navigator.userAgent) ||
           (navigator.maxTouchPoints && navigator.maxTouchPoints > 2)
  }

  setupMobileDetection() {
    if (this.isMobileDevice()) {
      if (this.hasCameraSectionTarget) {
        this.cameraSectionTarget.classList.remove('hidden')
      }
      if (this.hasDragTextTarget) {
        this.dragTextTarget.classList.add('hidden')
      }
    }
  }

  setupDragAndDrop() {
    // Prevent default drag behaviors on the whole document
    ['dragenter', 'dragover', 'dragleave', 'drop'].forEach(eventName => {
      document.body.addEventListener(eventName, this.preventDefaults.bind(this), false)
    })
  }

  preventDefaults(e) {
    e.preventDefault()
    e.stopPropagation()
  }

  dragEnter(e) {
    this.preventDefaults(e)
    this.dropZoneTarget.classList.add('border-indigo-500', 'bg-indigo-50')
  }

  dragOver(e) {
    this.preventDefaults(e)
    this.dropZoneTarget.classList.add('border-indigo-500', 'bg-indigo-50')
  }

  dragLeave(e) {
    this.preventDefaults(e)
    this.dropZoneTarget.classList.remove('border-indigo-500', 'bg-indigo-50')
  }

  drop(e) {
    this.preventDefaults(e)
    this.dropZoneTarget.classList.remove('border-indigo-500', 'bg-indigo-50')

    const files = e.dataTransfer.files
    if (files.length > 0) {
      this.fileInputTarget.files = files
      this.previewImage(this.fileInputTarget)
    }
  }

  openFilePicker(e) {
    // Don't trigger if clicking on the remove button or preview area
    if (e.target.closest('[data-split-check-upload-target="imagePreview"]')) return
    this.fileInputTarget.click()
  }

  openCamera() {
    this.cameraInputTarget.click()
  }

  handleFileSelect(e) {
    this.previewImage(e.target)
  }

  handleCameraCapture(e) {
    this.previewImage(e.target)
  }

  previewImage(input) {
    if (input.files && input.files[0]) {
      const reader = new FileReader()

      reader.onload = (e) => {
        this.previewImgTarget.src = e.target.result
        this.fileNameTarget.textContent = input.files[0].name || 'Foto de camara'
        this.imagePreviewTarget.classList.remove('hidden')
        this.uploadContentTarget.classList.add('hidden')

        // Show submit button when image is attached
        this.submitBtnTarget.classList.remove('hidden')

        // Scroll to submit button on mobile
        setTimeout(() => {
          this.submitBtnTarget.scrollIntoView({ behavior: 'smooth', block: 'nearest' })
        }, 100)
      }

      reader.readAsDataURL(input.files[0])

      // If image came from camera, disable the other file input to avoid conflicts
      if (input === this.cameraInputTarget) {
        this.fileInputTarget.disabled = true
      } else {
        this.cameraInputTarget.disabled = true
      }
    }
  }

  clearImage() {
    this.previewImgTarget.src = ''
    this.imagePreviewTarget.classList.add('hidden')
    this.uploadContentTarget.classList.remove('hidden')
    this.fileInputTarget.value = ''
    this.fileInputTarget.disabled = false
    this.cameraInputTarget.value = ''
    this.cameraInputTarget.disabled = false

    // Hide submit button when image is removed
    this.submitBtnTarget.classList.add('hidden')
  }

  submitForm() {
    this.submitTextTarget.classList.add('hidden')
    this.submitLoadingTarget.classList.remove('hidden')
    this.submitLoadingTarget.classList.add('flex')
    this.submitBtnTarget.disabled = true
    this.submitBtnTarget.classList.add('opacity-75', 'cursor-not-allowed')
    this.submitBtnTarget.classList.remove('hover:bg-indigo-700')
  }
}