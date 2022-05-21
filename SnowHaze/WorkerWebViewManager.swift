//
//  WorkerWebViewManager.swift
//  SnowHaze
//
//
//  Copyright © 2017 Illotros GmbH. All rights reserved.
//

import Foundation
import WebKit

protocol WorkerWebViewManagerDelegate: AnyObject {
	func webViewManagerDidFailLoad(_ manager: WorkerWebViewManager)
	func webViewManagerDidFinishLoad(_ manager: WorkerWebViewManager)
	func webViewManager(_ manager: WorkerWebViewManager, didMakeProgress progress: Double)
	func webViewManaget(_ manager: WorkerWebViewManager, didUpgradeLoadOf url: URL)
	func webViewManaget(_ manager: WorkerWebViewManager, isLoading url: URL?)
}

extension WorkerWebViewManagerDelegate {
	func webViewManagerDidFailLoad(_ manager: WorkerWebViewManager) { }
	func webViewManagerDidFinishLoad(_ manager: WorkerWebViewManager) { }
}

class WorkerWebViewManager: NSObject, WebViewManager {
	let timeout: TimeInterval = 15
	let tab: Tab
	weak var delegate: WorkerWebViewManagerDelegate?

	private var isLocalOnly = false

	private var dec: (() -> ())?
	private var observer: NSObjectProtocol?

	var lastUpgrade = HTTPSUpgradeState()

	private var actionTryList: [PolicyManager.Action] = []

	init(tab: Tab) {
		self.tab = tab
	}

	private var observations = Set<NSKeyValueObservation>()

	let securityCookie: String = String.secureRandom()

	private(set) lazy var webView: WKWebView = {
		precondition(!tab.deleted)
		let policy = PolicyManager.manager(for: tab)
		let config = policy.webViewConfiguration(for: self)
		if let store = tab.controller?.dataStore {
			(config.websiteDataStore, config.processPool) = store
		} else {
			let store = policy.dataStore
			(config.websiteDataStore, config.processPool) = (store.store, store.pool ?? WKProcessPool())
		}
		let ret = WKWebView(frame: .zero, configuration: config)
		ret.allowsLinkPreview = false
		ret.customUserAgent = tab.controller?.userAgent ?? policy.userAgent
		ret.navigationDelegate = self
		ret.backgroundColor = .background

		DispatchQueue.main.async {
			self.observations.insert(ret.observe(\.estimatedProgress, options: .initial, changeHandler: { [weak self] webView, _ in
				if let self = self {
					self.delegate?.webViewManager(self, didMakeProgress: webView.estimatedProgress)
				}
			}))

			self.observations.insert(ret.observe(\.isLoading, options: .initial, changeHandler: { [weak self] webView, _ in
				if webView.isLoading, !(self?.isLocalOnly ?? false) {
					self?.dec = InUseCounter.network.inc()
				} else {
					self?.dec?()
					self?.dec = nil
				}
			}))
		}
		observations.insert(ret.observe(\.url, options: .initial, changeHandler: { [weak self] webView, _ in
			if let self = self {
				self.update(for: webView.url, webView: webView)
				self.delegate?.webViewManaget(self, isLoading: webView.url)
			}
		}))
		return ret
	}()

	func load(userInput input: String) {
		let policy = PolicyManager.manager(for: tab)
		load(policy.actionList(for: input, in: tab))
	}

	func load(url: URL?) {
		if let url = url {
			load([.load(url, upgraded: false)])
		}
	}

	func loadLocal(html: String) {
		isLocalOnly = true
		webView.loadHTMLString(html, baseURL: nil)
	}

	private func load(request: URLRequest) {
		guard !tab.deleted else {
			tabDeletedAbort()
			return
		}
		isLocalOnly = false
		update(for: request.url, webView: webView)
		rawLoad(request, in: webView)
	}

	private func load(_ list: [PolicyManager.Action]) {
		lastUpgrade.reset()
		actionTryList.removeAll()
		webView.stopLoading()
		actionTryList = list
		if actionTryList.isEmpty {
			return
		}
		let action = actionTryList.removeFirst()
		switch action {
			case .load(let url, let upgraded):
				let request = actionTryList.isEmpty ? URLRequest(url: url) : URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: timeout)
				if upgraded {
					delegate?.webViewManaget(self, didUpgradeLoadOf: url)
				}
				load(request: request)
		}
	}

	deinit {
		if let observer = observer {
			NotificationCenter.default.removeObserver(observer)
		}
		let insecureHandler = webView.configuration.urlSchemeHandler(forURLScheme: "tor") as? TorSchemeHandler
		insecureHandler?.cleanup()
		let secureHandler = webView.configuration.urlSchemeHandler(forURLScheme: "tors") as? TorSchemeHandler
		secureHandler?.cleanup()
		webView.stopLoading()
		dec?()
	}
}

extension WorkerWebViewManager: WKNavigationDelegate {
	func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
		delegate?.webViewManagerDidFinishLoad(self)
	}

	func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
		delegate?.webViewManagerDidFailLoad(self)
	}

	func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
		if !actionTryList.isEmpty {
			let action = actionTryList.removeLast()
			switch action {
				case .load(let url, let upgraded):
					let request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: timeout)
					if upgraded {
						delegate?.webViewManaget(self, didUpgradeLoadOf: url)
					}
					load(request: request)
			}
		} else {
			delegate?.webViewManagerDidFailLoad(self)
		}
	}

	@available(iOS 13, *)
	func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> ()) {
		self.webView(webView, decidePolicyFor: navigationAction) { [weak self] decision in
			guard let self = self, !self.tab.deleted else {
				if #available(iOS 14, *) {
					preferences.allowsContentJavaScript = false
				}
				preferences.preferredContentMode = .recommended
				decisionHandler(.cancel, preferences)
				return
			}
			let policyURL = navigationAction.loadedMainURL ?? webView.url
			let policy = PolicyManager.manager(for: policyURL, in: self.tab)
			if #available(iOS 14, *) {
				preferences.allowsContentJavaScript = policy.allowJS
			}
			preferences.preferredContentMode = policy.renderAsDesktopSite ? .desktop : .mobile
			decisionHandler(decision, preferences)
		}
	}

	func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> ()) {
		lastUpgrade.dec()
		guard !tab.deleted || isLocalOnly else {
			tabDeletedAbort()
			decisionHandler(.cancel)
			return
		}
		let actionURL = navigationAction.request.url?.detorified ?? navigationAction.request.url
		let isHTTPGet = navigationAction.request.isHTTPGet
		if actionURL != lastUpgrade.url, let url = upgradeURL(for: actionURL, navigationAction: navigationAction) {
			delegate?.webViewManaget(self, didUpgradeLoadOf: url)
			decisionHandler(.cancel)
			var newRequest = navigationAction.request
			newRequest.url = url
			load(request: newRequest)
			lastUpgrade.set(url)
			return
		}
		if let url = strippedURL(for: navigationAction) {
			decisionHandler(.cancel)
			var newRequest = navigationAction.request
			newRequest.url = url
			load(request: newRequest)
			return
		}
		let policyURL = navigationAction.loadedMainURL ?? webView.url
		let policy = PolicyManager.manager(for: policyURL, in: tab)
		if policy.shouldBlockLoad(of: actionURL) || (policy.preventXSS && actionURL?.potentialXSS ?? false) {
			decisionHandler(.cancel)
			delegate?.webViewManagerDidFailLoad(self)
			return
		}
		if navigationAction.request.isHTTPGet && navigationAction.targetFrame?.isMainFrame ?? true, let url = policy.torifyIfNecessary(for: tab, url: navigationAction.request.url) {
			decisionHandler(.cancel)
			load(url: url)
			return
		}
		if policy.stripTrackingURLParameters && isHTTPGet, let original = actionURL {
			let db = DomainList.dbManager
			let table = "parameter_stripping"
			let result = URLParamStripRule.changedURL(for: original, from: db, table: table)
			if !result.stripped.isEmpty {
				decisionHandler(.cancel)
				load(url: result.url)
				return
			}
		}
		if policy.skipRedirects && isHTTPGet, let original = actionURL, let url = Redirector.shared.redirect(original) {
			decisionHandler(.cancel)
			load(url: url)
			return
		}
		if let url = actionURL {
			guard let controller = tab.controller else {
				decisionHandler(.cancel)
				return
			}
			policy.dangerReasons(for: url, in: controller) { [weak self] dangers in
				guard let me = self, !me.tab.deleted else {
					decisionHandler(.cancel)
					self?.tabDeletedAbort()
					return
				}
				if dangers.isEmpty {
					me.update(for: policyURL, webView: webView)
					decisionHandler(.allow)
				} else {
					decisionHandler(.cancel)
					me.delegate?.webViewManagerDidFailLoad(me)
				}
			}
		} else {
			update(for: policyURL, webView: webView)
			decisionHandler(.allow)
		}
	}

	func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> ()) {
		let space = challenge.protectionSpace
		guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
			completionHandler(.performDefaultHandling, nil)
			return
		}
		guard let controller = tab.controller, !tab.deleted else {
			completionHandler(.cancelAuthenticationChallenge, nil)
			return
		}
		controller.accept(space.serverTrust!, for: space.host) { result in
			completionHandler(result ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
		}
	}

	func webView(_ webView: WKWebView, authenticationChallenge challenge: URLAuthenticationChallenge, shouldAllowDeprecatedTLS decisionHandler: @escaping (Bool) -> ()) {
		guard !tab.deleted else {
			decisionHandler(false)
			tabDeletedAbort()
			return
		}
		let domain = PolicyDomain(host: webView.url?.host)
		let policy = PolicyManager.manager(for: domain, in: tab)
		decisionHandler(!policy.blockDeprecatedTLS)
	}
}

/// internals
private extension WorkerWebViewManager {
	func strippedURL(for navigationAction: WKNavigationAction) -> URL? {
		let rawURL = navigationAction.request.url
		guard let url = rawURL?.detorified ?? rawURL, navigationAction.targetFrame?.isMainFrame ?? false else {
			return nil
		}
		let policyURL = navigationAction.loadedMainURL ?? webView.url
		guard navigationAction.request.isHTTPGet else {
			return nil
		}
		let policy = PolicyManager.manager(for: policyURL, in: tab)
		guard policy.stripTrackingURLParameters else {
			return nil
		}
		let (newUrl, changes) = URLParamStripRule.changedURL(for: url, from: DomainList.dbManager, table: "parameter_stripping")
		return changes.isEmpty ? nil : newUrl
	}

	func update(for url: URL?, webView: WKWebView) {
		let policy = PolicyManager.manager(for: url, in: tab)
		update(policy: policy, webView: webView)
	}

	func tabDeletedAbort() {
		isLocalOnly = true
		loadLocal(html: BrowserPageGenerator(type: .tabDeleted).getHTML())
	}
}

extension WorkerWebViewManager {
	func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
		didReceive(scriptMessage: message, from: userContentController)
	}
}
