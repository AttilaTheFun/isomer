package dev.swiftmap.runtime

import org.json.JSONObject

/** One on-screen annotation's projected position (dp). */
class AnnotationAnchor(val id: String, val x: Double, val y: Double, val title: String)

/** The slim per-frame payload from Swift (rendering happens there, through
 * SwiftGPU): camera state + annotation anchors for the callout overlay. */
class FrameInfo(
    val latitude: Double,
    val longitude: Double,
    val zoom: Double,
    val annotationAnchors: List<AnnotationAnchor>,
) {
    companion object {
        fun parse(json: String): FrameInfo {
            val root = JSONObject(json)
            val annsJSON = root.optJSONArray("anns")
            val anchors = ArrayList<AnnotationAnchor>(annsJSON?.length() ?: 0)
            if (annsJSON != null) {
                for (i in 0 until annsJSON.length()) {
                    val a = annsJSON.getJSONObject(i)
                    anchors.add(
                        AnnotationAnchor(a.getString("i"), a.getDouble("x"), a.getDouble("y"), a.getString("t"))
                    )
                }
            }
            return FrameInfo(
                root.getDouble("lat"), root.getDouble("lon"), root.getDouble("zoom"),
                anchors,
            )
        }
    }
}
