import Hummingbird
import Logging
import Metrics
import Prometheus
import CoreMetrics

struct MeetrecMetrics: Sendable {
    private let registry: PrometheusCollectorRegistry
    private let meetingGauge: CoreMetrics.Gauge
    private let recordingGauge: CoreMetrics.Gauge
    private let microphoneGauge: CoreMetrics.Gauge
    private let recordingStartsCounter: CoreMetrics.Counter

    init() {
        let registry = PrometheusCollectorRegistry()
        MetricsSystem.bootstrap(PrometheusMetricsFactory(registry: registry))

        self.registry = registry
        self.meetingGauge = CoreMetrics.Gauge(label: "meetrec_in_meeting")
        self.recordingGauge = CoreMetrics.Gauge(label: "meetrec_recording")
        self.microphoneGauge = CoreMetrics.Gauge(label: "meetrec_microphone_active")
        self.recordingStartsCounter = CoreMetrics.Counter(label: "meetrec_recording_starts_total")

        self.meetingGauge.record(0)
        self.recordingGauge.record(0)
        self.microphoneGauge.record(0)
    }

    func updateMeeting(_ isInMeeting: Bool) {
        meetingGauge.record(isInMeeting ? 1 : 0)
    }

    func updateRecording(from previousState: Bool, to isRecording: Bool) {
        recordingGauge.record(isRecording ? 1 : 0)
        if !previousState && isRecording {
            recordingStartsCounter.increment()
        }
    }

    func updateMicrophone(_ isActive: Bool) {
        microphoneGauge.record(isActive ? 1 : 0)
    }

    func application(port: Int, logger: Logger) -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        let registry = self.registry
        router.get("metrics") { request, context -> Response in
            var response = registry.emitToString().response(from: request, context: context)
            response.headers[.contentType] = "text/plain; version=0.0.4; charset=utf-8"
            return response
        }

        return Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: port)),
            onServerRunning: { _ in
                logger.info("Prometheus metrics endpoint available at http://127.0.0.1:\(port)/metrics")
            },
            logger: logger
        )
    }
}
