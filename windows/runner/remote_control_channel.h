#ifndef RUNNER_REMOTE_CONTROL_CHANNEL_H_
#define RUNNER_REMOTE_CONTROL_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
RegisterRemoteControlChannel(flutter::BinaryMessenger* messenger);

#endif  // RUNNER_REMOTE_CONTROL_CHANNEL_H_
