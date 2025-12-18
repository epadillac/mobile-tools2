// app/javascript/controllers/bridge/share_controller.js
import { BridgeComponent } from "@hotwired/hotwire-native-bridge";

export default class extends BridgeComponent {
  static component = "share";

  connect() {
    super.connect();
  }

  open() {
    const element = this.bridgeElement;

    // Get share data from bridge attributes
    const url = element.bridgeAttribute("url") || window.location.href;
    const title = element.bridgeAttribute("title") || document.title;
    const text = element.bridgeAttribute("text") || "";
    const subject = element.bridgeAttribute("subject") || title;
    const color = element.bridgeAttribute("color");

    // Build the share payload
    const payload = { url, title, text, subject };

    // Only include color if provided
    if (color) {
      payload.color = color;
    }

    this.send("open", payload, () => {});
  }
}
