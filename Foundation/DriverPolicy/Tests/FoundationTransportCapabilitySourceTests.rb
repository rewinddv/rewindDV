# Copyright 2026 Rewind Digital, LLC
# SPDX-License-Identifier: Apache-2.0

source = File.read(File.expand_path(
  '../../../ASFWDriver/UserClient/Handlers/AVCHandler.cpp', __dir__))
core = File.read(File.expand_path(
  '../../../ASFWDriver/UserClient/Core/ASFWDriverUserClient.cpp', __dir__))
iig = File.read(File.expand_path(
  '../../../ASFWDriver/UserClient/Core/ASFWDriverUserClient.iig', __dir__))

def function_body(source, return_type, name, following_return_type, following_name)
  start_at = source.index("#{return_type} #{name}(") or raise "missing #{name}"
  end_at = source.index("#{following_return_type} #{following_name}(", start_at) or
    raise "missing #{following_name}"
  source[start_at...end_at]
end

reserve = function_body(source, 'kern_return_t',
                        'ReserveFoundationTransportCapabilityProbe', 'void',
                        'ObserveFoundationTransportCapabilityAttempt')
attempt = function_body(source, 'void',
                        'ObserveFoundationTransportCapabilityAttempt', 'void',
                        'ObserveFoundationTransportCapabilityResponse')
response = function_body(source, 'void',
                         'ObserveFoundationTransportCapabilityResponse', 'bool',
                         'IsPublishableConditionalDeckProof')
complete = function_body(source, 'void',
                         'CompleteFoundationTransportCapability', 'bool',
                         'IsPublishableConditionalDeckProof')
complete_start = source.index('void CompleteFoundationTransportCapability(') or
  raise 'missing CompleteFoundationTransportCapability'
proof_start = source.index('bool IsPublishableConditionalDeckProof(', complete_start) or
  raise 'missing IsPublishableConditionalDeckProof definition'
proof_end = source.index('void PublishConditionalDeckProofIfEligible(', proof_start) or
  raise 'missing PublishConditionalDeckProofIfEligible definition'
proof_check = source[proof_start...proof_end]
publish = function_body(source, 'void',
                        'PublishConditionalDeckProofIfEligible', 'void',
                        'CloseFoundationTransportCapabilitySubmission')
close = function_body(source, 'void',
                      'CloseFoundationTransportCapabilitySubmission', 'void',
                      'FailFoundationTransportCapabilityIfPending')
submit = function_body(source, 'kern_return_t',
                       'AVCHandler::SubmitTransportCapabilityProbe', 'kern_return_t',
                       'AVCHandler::GetTransportCapabilityResult')
deck_submit = function_body(source, 'kern_return_t',
                            'AVCHandler::SubmitDeckControl', 'kern_return_t',
                            'AVCHandler::GetDeckControlResult')

raise 'conditional reprobe does not revoke prior proof at admission' unless
  reserve.include?('store.conditionalDeckProofs.erase(request.command)')
raise 'probe attempt is not consumed at admission' unless
  reserve.include?('store.consumedAttemptIDs.insert(request.attemptID)')
raise 'probe does not share the exclusive inspector admission token' unless
  reserve.include?('FoundationPolicy::ActivityKind::kInspector')
predicate = 'ShouldObserveTransportCapabilityEvidence('
raise 'attempt observer lacks publication fence' unless attempt.include?(predicate)
raise 'response observer lacks publication fence' unless response.include?(predicate)
raise 'publication fence must occur exactly twice' unless source.scan(predicate).length == 2
raise 'transport mismatch is not authoritative over raw payload shape' unless
  response.include?('evidence.classification == FCPClass::kMismatch')
raise 'conditional proof is not gated by policy terminal evidence' unless
  publish.include?('ShouldInstallConditionalDeckAuthorization')
policy = File.read(File.expand_path('../FoundationDriverPolicy.cpp', __dir__))
raise 'conditional proof does not reject response evidence overflow' unless
  policy.include?('result.responseEventOverflow != 0')
raise 'conditional proof is not bound to the retained terminal event' unless
  policy.include?('terminal.fcpAttemptID == result.fcpAttemptID') &&
    policy.include?('ClassifyTransportCapabilityResponse(command, terminalPayload)')
%w[guid deviceIncarnation routeEpoch generation nodeId].each do |field|
  raise "proof omits exact route field #{field}" unless proof_check.include?(field)
end
raise 'synchronous completion does not publish before ready' unless
  close.index('PublishConditionalDeckProofIfEligible') < close.index('record.ready =')
raise 'asynchronous completion does not publish before ready release' unless
  complete.include?('PublishConditionalDeckProofIfEligible(store, record)')
raise 'probe retry policy is not never' unless
  submit.include?('policy.retryClass = Protocols::AVC::FCPRetryClass::kNever')
raise 'probe queue policy is not reject' unless
  submit.include?('policy.queuePolicy = Protocols::AVC::FCPQueuePolicy::kReject')
raise 'probe permits interim extension' unless
  submit.include?('policy.maximumInterimResponses = 0')
raise 'probe accepts caller-selected raw frames' if submit.include?('request->commandData')
raise 'deck submit does not consult driver-global conditional proof' unless
  deck_submit.include?('HasFoundationConditionalDeckProof')
raise 'catalog selector is not wired' unless
  core.include?('kMethodGetTransportCapabilityCatalog')
raise 'probe selector is not wired' unless
  core.include?('kMethodSubmitTransportCapabilityProbe')
raise 'result selector is not wired' unless
  core.include?('kMethodGetTransportCapabilityResult')
{
  'kMethodGetTransportCapabilityCatalog' => 75,
  'kMethodSubmitTransportCapabilityProbe' => 76,
  'kMethodGetTransportCapabilityResult' => 77
}.each do |name, selector|
  raise "IIG selector mismatch for #{name}" unless
    iig.match?(/#{name}\s*=\s*#{selector}/)
end

puts 'Foundation transport capability source gates passed: exact-route proof, no retry, no caller frames, immutable publication'
