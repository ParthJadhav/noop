package com.noop.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.noop.R

/**
 * Current Terms of Use version. Bump on a MATERIAL change (risk / liability / medical / affiliation
 * wording) to re-prompt every user for a fresh acknowledgment; leave it for typo fixes. Mirrors macOS
 * `Terms.currentVersion`. The full text ships in TERMS.md.
 */
object Terms {
    const val CURRENT_VERSION = "1.1"

    /**
     * Plain-English summary of TERMS.md §1–§6 — kept identical to the macOS `Terms.points`. Each is
     * a (headline, body) pair of string-resource ids so the gate is localized like the rest of the
     * app (PR #984); the English source wording lives in values/strings.xml, byte-identical to what
     * used to be hardcoded here. The binding text stays TERMS.md — a translation is a courtesy, not
     * the agreement.
     */
    val points: List<Pair<Int, Int>> = listOf(
        R.string.terms_point_independent_head to R.string.terms_point_independent_body,
        R.string.terms_point_tos_head to R.string.terms_point_tos_body,
        R.string.terms_point_experimental_head to R.string.terms_point_experimental_body,
        R.string.terms_point_medical_head to R.string.terms_point_medical_body,
        R.string.terms_point_warranty_head to R.string.terms_point_warranty_body,
    )
}

/**
 * First-run acknowledgment gate (clickwrap), shown over everything — before onboarding, pairing, or
 * any Bluetooth access — until [Terms.CURRENT_VERSION] is accepted, and again if the terms materially
 * change. The user must tick the (un-pre-checked) box and tap Accept; acceptance is persisted by the
 * caller. Mirrors macOS `TermsGateView`.
 */
@Composable
fun TermsGateScreen(onAccept: () -> Unit) {
    var checked by remember { mutableStateOf(false) }
    Surface(modifier = Modifier.fillMaxSize(), color = Palette.surfaceBase) {
        Column(modifier = Modifier.fillMaxSize().padding(horizontal = 24.dp)) {
            Spacer(Modifier.height(40.dp))
            Text(stringResource(R.string.terms_title), style = NoopType.title1, color = Palette.textPrimary)
            Spacer(Modifier.height(4.dp))
            Text(
                stringResource(R.string.terms_subtitle),
                style = NoopType.subhead, color = Palette.textSecondary,
            )
            Spacer(Modifier.height(20.dp))

            Column(
                modifier = Modifier.weight(1f).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Terms.points.forEach { (head, body) ->
                    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                        Text(stringResource(head), style = NoopType.headline, color = Palette.textPrimary)
                        Text(stringResource(body), style = NoopType.footnote, color = Palette.textSecondary)
                    }
                }
                Text(
                    stringResource(R.string.terms_footer),
                    style = NoopType.footnote, color = Palette.textTertiary,
                )
            }

            Spacer(Modifier.height(12.dp))
            Row(verticalAlignment = Alignment.Top) {
                Checkbox(
                    checked = checked,
                    onCheckedChange = { checked = it },
                    colors = CheckboxDefaults.colors(checkedColor = Palette.accent),
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    stringResource(R.string.terms_checkbox),
                    style = NoopType.footnote, color = Palette.textPrimary,
                    modifier = Modifier.padding(top = 14.dp),
                )
            }
            Spacer(Modifier.height(12.dp))
            Button(
                onClick = onAccept,
                enabled = checked,
                modifier = Modifier.fillMaxWidth().padding(bottom = 24.dp),
                colors = ButtonDefaults.buttonColors(containerColor = Palette.accent),
            ) {
                Text(stringResource(R.string.terms_accept), style = NoopType.headline)
            }
        }
    }
}
