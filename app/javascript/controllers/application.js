import { Application } from "@hotwired/stimulus"
// import { controllers } from "@joemasilotti/bridge-components"

const application = Application.start()
// application.load(controllers)

// Configure Stimulus development experience
application.debug = false
window.Stimulus = application

export { application }
