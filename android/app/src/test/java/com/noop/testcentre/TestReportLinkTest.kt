package com.noop.testcentre

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Mirrors the Swift TestReportLinkTests. No Robolectric in this project (junit only), so we test the
 * pure reportUrlString() rather than the Uri wrapper. Must byte-match the Swift URLComponents output:
 * same field order, "%2C" for the label comma, "%5B"/"%5D" for the title brackets, "%20" for spaces.
 */
class TestReportLinkTest {

    @Test
    fun sleepProfileEncodesEveryFieldAndLabel() {
        val s = TestReportLink.reportUrlString(
            profile = TestDomain.SLEEP, title = "no score last night",
            version = "7.3.0", platform = "Android", osVersion = "15")
        assertTrue(s.startsWith("https://github.com/NoopApp/noop/issues/new?"))
        assertTrue(s.contains("template=bug_report.yml"))
        assertTrue(s.contains("labels=bug%2Ctest:sleep"))
        assertTrue(s.contains("version=7.3.0"))
        assertTrue(s.contains("platform=Android"))
        assertTrue(s.contains("os_version=15"))
        assertTrue(s.contains("test_profile=sleep"))
        assertTrue(s.contains("title=%5Bsleep%5D%20no%20score%20last%20night"))
    }

    @Test
    fun importProfileUsesImportWireId() {
        val s = TestReportLink.reportUrlString(
            profile = TestDomain.IMPORT, title = "x",
            version = "7.3.0", platform = "Android", osVersion = "15")
        assertTrue(s.contains("test_profile=import"))
        assertTrue(s.contains("labels=bug%2Ctest:import"))
    }

    @Test
    fun masterProfileLabelIsTestAll() {
        val s = TestReportLink.reportUrlString(
            profile = TestDomain.MASTER, title = "x",
            version = "7.3.0", platform = "Android", osVersion = "15")
        assertTrue(s.contains("labels=bug%2Ctest:all"))
    }

    // CAPTURE-A (#812): the log/what_happens body prefill

    @Test
    fun noReportTextAddsNoLogParam() {
        // Default (existing callers) must compose the SAME URL as before, with no `log` param.
        val s = TestReportLink.reportUrlString(
            profile = TestDomain.SLEEP, title = "x",
            version = "7.3.0", platform = "Android", osVersion = "15")
        assertFalse(s.contains("log="))
        assertFalse(s.contains("what_happens="))
    }

    @Test
    fun reportTextPrefillsLogTailInDetailsBlock() {
        val report = (1..200).joinToString("\n") { "line$it" }
        val s = TestReportLink.reportUrlString(
            profile = TestDomain.SLEEP, title = "x",
            version = "7.3.0", platform = "Android", osVersion = "15",
            reportText = report)
        assertTrue(s.contains("log="))
        // The <details> wrapper and the LAST line are present; the FIRST line (beyond the tail) is not.
        assertTrue(s.contains("%3Cdetails%3E")) // "<details>" encoded
        assertTrue(s.contains("line200"))
        assertFalse(s.contains("line1%0A")) // "line1\n" would only appear if the head leaked in
    }

    @Test
    fun oversizedLogIsDroppedNotTruncated() {
        // M2 (#812): a tail so long the URL would breach MAX_URL_LENGTH drops the log param entirely
        // (never a truncated <details>), keeping the short id fields + seed so the body is still non-empty.
        // Twin of the Swift testOversizedLogIsDroppedNotTruncated.
        val huge = (1..TestReportLink.LOG_TAIL_LINES).joinToString("\n") { "x".repeat(500) }
        val s = TestReportLink.reportUrlString(
            profile = TestDomain.SLEEP, title = "x",
            version = "7.3.0", platform = "Android", osVersion = "15",
            reportText = huge, whatHappensSeed = "it broke")
        assertFalse(s.contains("log=")) // dropped, not truncated
        assertTrue(s.contains("what_happens=")) // seed kept, body still non-empty
        assertTrue(s.length <= TestReportLink.MAX_URL_LENGTH) // under the GitHub prefill ceiling
    }

    @Test
    fun logDetailsBlockTakesTailAndNamesCount() {
        val report = (1..10).joinToString("\n") { "L$it" }
        val block = TestReportLink.logDetailsBlock(report, tailLines = 3)!!
        assertTrue(block.contains("last 3 lines"))
        assertTrue(block.contains("L8\nL9\nL10"))
        assertFalse(block.contains("L7"))
        assertFalse(block.contains("\u2014")) // no em-dash
    }

    @Test
    fun logDetailsBlockNullOnEmpty() {
        assertNull(TestReportLink.logDetailsBlock(""))
        assertNull(TestReportLink.logDetailsBlock("\n\n"))
    }

    @Test
    fun whatHappensSeedJoinsAnsweredPromptsInOrder() {
        val qs = listOf(
            Question(id = "q1", prompt = "When did it happen", kind = Question.Kind.TEXT),
            Question(id = "q2", prompt = "Did you wear it", kind = Question.Kind.YES_NO),
            Question(id = "q3", prompt = "Unanswered", kind = Question.Kind.TEXT),
        )
        val seed = TestReportLink.whatHappensSeed(qs, mapOf("q1" to "last night", "q2" to "yes"))
        assertEquals("When did it happen: last night\nDid you wear it: yes", seed)
    }

    @Test
    fun whatHappensSeedNullWhenNothingAnswered() {
        val qs = listOf(Question(id = "q1", prompt = "p", kind = Question.Kind.TEXT))
        assertNull(TestReportLink.whatHappensSeed(qs, emptyMap()))
        assertNull(TestReportLink.whatHappensSeed(qs, mapOf("q1" to "  ")))
    }

    @Test
    fun whatHappensSeedAddsParamWhenSupplied() {
        val s = TestReportLink.reportUrlString(
            profile = TestDomain.SLEEP, title = "x",
            version = "7.3.0", platform = "Android", osVersion = "15",
            whatHappensSeed = "it broke")
        assertTrue(s.contains("what_happens=it%20broke"))
    }
}
