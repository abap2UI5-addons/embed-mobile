package org.abap2ui5.mobileshell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The bridge goes to pages of the configured endpoint's origin only. Every
 * page that differs in scheme, host or port, and every URL that cannot be
 * read as http(s), must come back as not allowed.
 */
class BridgeOriginTest {

    private val endpoint = "https://host.example.com/sap/bc/z2ui5?sap-client=100"

    @Test
    fun `pages of the endpoint origin are allowed`() {
        assertTrue(BridgeOrigin.isAllowed("https://host.example.com/sap/bc/z2ui5?app=x#/detail", endpoint))
        assertTrue(BridgeOrigin.isAllowed("https://host.example.com/other/path", endpoint))
    }

    @Test
    fun `default port and case do not matter`() {
        assertTrue(BridgeOrigin.isAllowed("https://HOST.example.com:443/sap/bc/z2ui5", endpoint))
        assertTrue(BridgeOrigin.isAllowed("https://host.example.com:44300/x", "https://host.example.com:44300/sap/bc/z2ui5"))
    }

    @Test
    fun `another host is refused`() {
        assertFalse(BridgeOrigin.isAllowed("https://idp.example.com/saml/login", endpoint))
        assertFalse(BridgeOrigin.isAllowed("https://host.example.com.evil.test/sap/bc/z2ui5", endpoint))
        assertFalse(BridgeOrigin.isAllowed("https://host.example.com@evil.test/sap/bc/z2ui5", endpoint))
    }

    @Test
    fun `another scheme or port is refused`() {
        assertFalse(BridgeOrigin.isAllowed("http://host.example.com/sap/bc/z2ui5", endpoint))
        assertFalse(BridgeOrigin.isAllowed("https://host.example.com:8443/sap/bc/z2ui5", endpoint))
    }

    @Test
    fun `non http pages are refused`() {
        assertFalse(BridgeOrigin.isAllowed("about:blank", endpoint))
        assertFalse(BridgeOrigin.isAllowed("data:text/html,<p>x</p>", endpoint))
        assertFalse(BridgeOrigin.isAllowed("file:///android_asset/index.html", endpoint))
        assertFalse(BridgeOrigin.isAllowed(null, endpoint))
    }

    @Test
    fun `no usable endpoint allows nothing`() {
        assertFalse(BridgeOrigin.isAllowed("https://host.example.com/sap/bc/z2ui5", null))
        assertFalse(BridgeOrigin.isAllowed("https://host.example.com/sap/bc/z2ui5", ""))
        assertFalse(BridgeOrigin.isAllowed("https://host.example.com/sap/bc/z2ui5", "host.example.com"))
        assertNull(BridgeOrigin.origin("not a url"))
    }

    @Test
    fun `a late answer goes only to a main frame that kept the call's origin`() {
        val callOrigin = BridgeOrigin.origin("https://host.example.com/sap/bc/z2ui5?app=x")
        assertEquals("https://host.example.com:443", callOrigin)
        assertTrue(BridgeOrigin.isSameOrigin("https://HOST.example.com:443/sap/bc/z2ui5#/detail", callOrigin))
        assertFalse(BridgeOrigin.isSameOrigin("https://idp.example.com/saml/login", callOrigin))
        assertFalse(BridgeOrigin.isSameOrigin("https://host.example.com:8443/x", callOrigin))
        assertFalse(BridgeOrigin.isSameOrigin("about:blank", callOrigin))
        assertFalse(BridgeOrigin.isSameOrigin(null, callOrigin))
        // a call made while the main frame had no usable origin is never answered
        assertFalse(BridgeOrigin.isSameOrigin("https://host.example.com/", null))
    }

    @Test
    fun `the allowed-origin rule names the endpoint origin`() {
        assertEquals("https://host.example.com", BridgeOrigin.allowedOriginRule(endpoint))
        assertEquals("https://host.example.com", BridgeOrigin.allowedOriginRule("https://HOST.example.com:443/x"))
        assertEquals("https://host.example.com:44300",
            BridgeOrigin.allowedOriginRule("https://host.example.com:44300/sap/bc/z2ui5"))
        assertEquals("http://host.example.com:8080", BridgeOrigin.allowedOriginRule("http://host.example.com:8080/"))
        assertEquals("http://host.example.com", BridgeOrigin.allowedOriginRule("http://host.example.com/"))
        assertNull(BridgeOrigin.allowedOriginRule(null))
        assertNull(BridgeOrigin.allowedOriginRule("host.example.com"))
    }
}
