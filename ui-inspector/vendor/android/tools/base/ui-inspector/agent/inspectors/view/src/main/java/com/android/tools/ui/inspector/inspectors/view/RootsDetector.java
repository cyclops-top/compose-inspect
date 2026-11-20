/*
 * Copyright (C) 2026 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package com.android.tools.ui.inspector.inspectors.view;

import android.view.View;
import android.view.WindowManager.LayoutParams;
import android.view.inspector.WindowInspector;

import com.android.tools.agent.appinspection.XrHelper;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

final class RootsDetector {
    private RootsDetector() {}

    /**
     * Returns the last visible overlay when enabled, otherwise the focused visible root.
     *
     * <p>Note: This relies on {@link WindowInspector#getGlobalWindowViews()}, which requires API
     * 29+. This is intentional as the UI Inspector targets modern Android versions.
     */
    static List<View> getRootViews(XrHelper xrHelper, boolean skipOverlays) {
        List<View> xrViews = xrHelper.getXrViews();
        // If there are xr panels, xrViews already contains both XR panel views and regular
        // window views merged without duplicates.
        List<View> views = !xrViews.isEmpty() ? xrViews : getAndroidViews();
        List<View> roots = new ArrayList<>();
        for (View view : views) {
            int type = view.getLayoutParams() instanceof LayoutParams
                    ? ((LayoutParams) view.getLayoutParams()).type : 0;
            if (skipOverlays && type >= LayoutParams.FIRST_SYSTEM_WINDOW) continue;
            if (view.isShown() && view.isAttachedToWindow() && view.getWindowVisibility() == View.VISIBLE) {
                roots.add(view);
            }
        }
        if (roots.isEmpty()) throw new IllegalStateException("未找到可采集的窗口（可能已排除悬浮窗）");
        // Overlays commonly use FLAG_NOT_FOCUSABLE; focus remains on the Activity below.
        for (int index = roots.size() - 1; index >= 0; index--) {
            View root = roots.get(index);
            if (root.getLayoutParams() instanceof LayoutParams
                    && ((LayoutParams) root.getLayoutParams()).type >= LayoutParams.FIRST_SYSTEM_WINDOW) {
                return Collections.singletonList(root);
            }
        }
        for (int index = roots.size() - 1; index >= 0; index--) {
            if (roots.get(index).hasWindowFocus()) {
                View parent = roots.get(index);
                for (int i = roots.size() - 1; i >= 0; i--) {
                    View panel = roots.get(i);
                    if (!(panel.getLayoutParams() instanceof LayoutParams)) continue;
                    LayoutParams params = (LayoutParams) panel.getLayoutParams();
                    if (params.token == null || !params.token.equals(parent.getWindowToken())) continue;
                    switch (params.type) {
                        case LayoutParams.TYPE_APPLICATION_PANEL:
                        case LayoutParams.TYPE_APPLICATION_SUB_PANEL:
                        case LayoutParams.TYPE_APPLICATION_ATTACHED_DIALOG:
                        case LayoutParams.FIRST_SUB_WINDOW + 5: // TYPE_APPLICATION_ABOVE_SUB_PANEL (hidden API)
                            return Collections.singletonList(panel);
                        default:
                            break;
                    }
                }
                return Collections.singletonList(parent);
            }
        }
        return Collections.singletonList(roots.get(roots.size() - 1));
    }

    private static List<View> getAndroidViews() {
        return WindowInspector.getGlobalWindowViews();
    }
}
