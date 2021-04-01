//
//  PinningSessionDelegate.swift
//  SnowHaze
//
//
//  Copyright © 2018 Illotros GmbH. All rights reserved.
//

import Foundation

public class PinningSessionDelegate: NSObject, URLSessionDelegate {
	static let pinnedHosts = ["api.snowhaze.com", "ipv4.api.snowhaze.com", "ipv6.api.snowhaze.com"]

	private static let api3Cert = SecPolicyEvaluator.cert(named: "api3")!

	static let pinnedCerts = [api3Cert]

	public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> ()) {
		let space = challenge.protectionSpace
		guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
			completionHandler(.performDefaultHandling, nil)
			return
		}
		guard PinningSessionDelegate.pinnedHosts.contains(space.host) else {
			completionHandler(.cancelAuthenticationChallenge, nil)
			return
		}
		let policy = SecPolicyEvaluator(domain: space.host, trust: space.serverTrust!)
		let certs = PinningSessionDelegate.pinnedCerts
		policy.evaluate(.strict) { result in
			if result && policy.pin(with: .certs(certs)) {
				completionHandler(.performDefaultHandling, nil)
			} else {
				completionHandler(.cancelAuthenticationChallenge, nil)
			}
		}
	}
}
