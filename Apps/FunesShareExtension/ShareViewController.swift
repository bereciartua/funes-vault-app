import SwiftUI
import UIKit

/// The share extension (`com.funesvault.ios.share`). Task 5.3 sets up the target; task 5.4 makes
/// it save the shared text or URL, with an optional note, to the capture queue. It never sends
/// anything itself.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareView { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        })
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

private struct ShareView: View {
    let done: () -> Void

    var body: some View {
        NavigationStack {
            Text("Saving to Funes from the share sheet comes in the next build.")
                .multilineTextAlignment(.center)
                .padding()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) }
                }
        }
    }
}
