import json
import logging
import os
import time

import requests
from confluent_kafka import Producer

# 로그 형식 설정: 시간 + 레벨 + 메시지
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
logger = logging.getLogger(__name__)

# Wikipedia 실시간 편집 이벤트 SSE 엔드포인트
SSE_URL = "https://stream.wikimedia.org/v2/stream/recentchange"

# Kafka 브로커 주소 — 환경변수로 주입, 기본값은 K8s 내부 서비스 주소
KAFKA_BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP", "wikipulse-kafka-bootstrap.kafka.svc:9092")

# 편집 이벤트를 발행할 토픽
TOPIC = "wiki-edits"

# SSE 연결 끊겼을 때 재연결 전 대기 시간 (초)
RECONNECT_DELAY = 5


def delivery_report(err, msg):
    """Kafka 전송 결과 콜백 — 실패 시 로그 출력."""
    if err:
        logger.error("Delivery failed: %s", err)


def create_producer():
    """Kafka 프로듀서 생성."""
    return Producer({"bootstrap.servers": KAFKA_BOOTSTRAP})


def stream(producer):
    """SSE 스트림에 연결해서 편집 이벤트를 읽고 Kafka에 발행."""
    logger.info("Connecting to Wikipedia SSE stream...")

    # stream=True: 응답 본문을 한 번에 받지 않고 한 줄씩 스트리밍
    # User-Agent 없으면 Wikimedia가 403으로 차단
    headers = {"User-Agent": "wikipulse-sse-consumer/1.0 (https://github.com/cksdud1202a/wikipulse-lab)"}
    response = requests.get(SSE_URL, stream=True, timeout=30, headers=headers)
    response.raise_for_status()  # 4xx/5xx 응답이면 예외 발생
    logger.info("Connected.")

    for line in response.iter_lines():
        if not line:
            continue  # 빈 줄은 SSE 이벤트 구분자 — 무시

        line = line.decode("utf-8")

        # SSE 형식: "data: {...}" — data: 로 시작하는 줄만 실제 이벤트
        if not line.startswith("data:"):
            continue

        # "data: " 이후의 JSON 문자열 추출
        raw = line[len("data:"):].strip()
        try:
            event = json.loads(raw)
        except json.JSONDecodeError:
            continue  # JSON 파싱 실패 시 해당 이벤트 스킵

        # Kafka wiki-edits 토픽에 이벤트 원본 전송
        producer.produce(
            TOPIC,
            value=json.dumps(event).encode("utf-8"),
            callback=delivery_report,
        )
        # 내부 큐에 쌓인 메시지 전송 처리 (non-blocking)
        producer.poll(0)
        logger.debug("Sent: %s", event.get("title"))


def main():
    """프로듀서 생성 후 스트림 루프 실행. 에러 발생 시 자동 재연결."""
    producer = create_producer()
    while True:
        try:
            stream(producer)
        except Exception as e:
            # 네트워크 오류, 타임아웃 등 — 잠시 대기 후 재연결
            logger.error("Stream error: %s — reconnecting in %ds", e, RECONNECT_DELAY)
            time.sleep(RECONNECT_DELAY)


if __name__ == "__main__":
    main()
