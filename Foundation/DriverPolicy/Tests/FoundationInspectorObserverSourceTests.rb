# Copyright 2026 Rewind Digital, LLC
# SPDX-License-Identifier: Apache-2.0

source = File.read(File.expand_path('../../../ASFWDriver/UserClient/Handlers/AVCHandler.cpp', __dir__))

def function_body(source, name, following_name)
  start_at = source.index("void #{name}(") or raise "missing #{name}"
  end_at = source.index("void #{following_name}(", start_at) or raise "missing #{following_name}"
  source[start_at...end_at]
end

inspector_attempt = function_body(source, 'ObserveFoundationInspectorAttempt',
                                  'ObserveFoundationInspectorResponse')
inspector_response = function_body(source, 'ObserveFoundationInspectorResponse',
                                   'CompleteFoundationInspector')
deck_attempt = function_body(source, 'ObserveFoundationFCPAttempt',
                             'ObserveFoundationFCPResponse')
deck_response = function_body(source, 'ObserveFoundationFCPResponse',
                              'CompleteFoundationDeckControl')

predicate = 'ShouldObserveInspectorEvidence(result->second.ready)'
raise 'inspector attempt observer lacks publication fence' unless inspector_attempt.include?(predicate)
raise 'inspector response observer lacks publication fence' unless inspector_response.include?(predicate)
raise 'deck attempt observer was changed out of scope' if deck_attempt.include?(predicate)
raise 'deck response observer was changed out of scope' if deck_response.include?(predicate)
raise 'publication fence must occur exactly twice' unless source.scan(predicate).length == 2

reserve_start = source.index('kern_return_t ReserveFoundationInspector(') or
  raise 'missing inspector reservation'
reserve_end = source.index('bool InspectorRouteMatches(', reserve_start) or
  raise 'missing inspector reservation end'
reserve = source[reserve_start...reserve_end]
high_water_update = reserve.index('store.inspectorAttemptHighWater = request.attemptID') or
  raise 'shared inspector high-water is not consumed'
result_reservation = reserve.index('store.results.emplace(requestID, record)') or
  raise 'missing owned result reservation'
reservation_check = reserve.index('if (!inserted)', result_reservation) or
  raise 'owned result reservation success is unchecked'
activity_admission = reserve.index('TryAcquireActivity(activityKind)') or
  raise 'missing activity admission'
raise 'high-water advanced before admission completed' unless
  high_water_update > reservation_check && reservation_check > result_reservation &&
    result_reservation > activity_admission
raise 'inspector still uses bounded consumed-ID history' if
  reserve.include?('consumedAttemptIDs') || reserve.include?('kMaximumLifetimeAttempts')

puts 'Foundation inspector source gates passed: observer fences; shared O(1) high-water ordering; no inspector lifetime ceiling'
