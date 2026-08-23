// DART 재무 수집 백필: 2023~2026 사업연도 × 보고서 조합
// 2026은 1분기/반기까지만(3분기·연간 미공시)
List<String> fullYears = new List<String>{ '2023', '2024', '2025' };
List<String> reportCodes = new List<String>{ '11013', '11012', '11014', '11011' }; // 1분기, 반기, 3분기, 연간

Integer enqueued = 0;
for (String yr : fullYears) {
    for (String rc : reportCodes) {
        Database.executeBatch(new DartCollectionBatch(yr, rc), 1);
        enqueued++;
    }
}
// 2026: 1분기 + 반기만
for (String rc : new List<String>{ '11013', '11012' }) {
    Database.executeBatch(new DartCollectionBatch('2026', rc), 1);
    enqueued++;
}
System.debug('큐에 넣은 배치 수: ' + enqueued);
