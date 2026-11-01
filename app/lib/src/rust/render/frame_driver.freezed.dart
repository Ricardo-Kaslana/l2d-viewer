// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'frame_driver.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
  'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models',
);

/// @nodoc
mixin _$FrameEvent {
  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(int width, int height) initial,
    required TResult Function(SharedTextureHandle field0) updated,
    required TResult Function(String field0) failed,
    required TResult Function() idle,
  }) => throw _privateConstructorUsedError;
  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(int width, int height)? initial,
    TResult? Function(SharedTextureHandle field0)? updated,
    TResult? Function(String field0)? failed,
    TResult? Function()? idle,
  }) => throw _privateConstructorUsedError;
  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(int width, int height)? initial,
    TResult Function(SharedTextureHandle field0)? updated,
    TResult Function(String field0)? failed,
    TResult Function()? idle,
    required TResult orElse(),
  }) => throw _privateConstructorUsedError;
  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(FrameEvent_Initial value) initial,
    required TResult Function(FrameEvent_Updated value) updated,
    required TResult Function(FrameEvent_Failed value) failed,
    required TResult Function(FrameEvent_Idle value) idle,
  }) => throw _privateConstructorUsedError;
  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(FrameEvent_Initial value)? initial,
    TResult? Function(FrameEvent_Updated value)? updated,
    TResult? Function(FrameEvent_Failed value)? failed,
    TResult? Function(FrameEvent_Idle value)? idle,
  }) => throw _privateConstructorUsedError;
  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(FrameEvent_Initial value)? initial,
    TResult Function(FrameEvent_Updated value)? updated,
    TResult Function(FrameEvent_Failed value)? failed,
    TResult Function(FrameEvent_Idle value)? idle,
    required TResult orElse(),
  }) => throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $FrameEventCopyWith<$Res> {
  factory $FrameEventCopyWith(
    FrameEvent value,
    $Res Function(FrameEvent) then,
  ) = _$FrameEventCopyWithImpl<$Res, FrameEvent>;
}

/// @nodoc
class _$FrameEventCopyWithImpl<$Res, $Val extends FrameEvent>
    implements $FrameEventCopyWith<$Res> {
  _$FrameEventCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of FrameEvent
  /// with the given fields replaced by the non-null parameter values.
}

/// @nodoc
abstract class _$$FrameEvent_InitialImplCopyWith<$Res> {
  factory _$$FrameEvent_InitialImplCopyWith(
    _$FrameEvent_InitialImpl value,
    $Res Function(_$FrameEvent_InitialImpl) then,
  ) = __$$FrameEvent_InitialImplCopyWithImpl<$Res>;
  @useResult
  $Res call({int width, int height});
}

/// @nodoc
class __$$FrameEvent_InitialImplCopyWithImpl<$Res>
    extends _$FrameEventCopyWithImpl<$Res, _$FrameEvent_InitialImpl>
    implements _$$FrameEvent_InitialImplCopyWith<$Res> {
  __$$FrameEvent_InitialImplCopyWithImpl(
    _$FrameEvent_InitialImpl _value,
    $Res Function(_$FrameEvent_InitialImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of FrameEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({Object? width = null, Object? height = null}) {
    return _then(
      _$FrameEvent_InitialImpl(
        width: null == width
            ? _value.width
            : width // ignore: cast_nullable_to_non_nullable
                  as int,
        height: null == height
            ? _value.height
            : height // ignore: cast_nullable_to_non_nullable
                  as int,
      ),
    );
  }
}

/// @nodoc

class _$FrameEvent_InitialImpl extends FrameEvent_Initial {
  const _$FrameEvent_InitialImpl({required this.width, required this.height})
    : super._();

  @override
  final int width;
  @override
  final int height;

  @override
  String toString() {
    return 'FrameEvent.initial(width: $width, height: $height)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$FrameEvent_InitialImpl &&
            (identical(other.width, width) || other.width == width) &&
            (identical(other.height, height) || other.height == height));
  }

  @override
  int get hashCode => Object.hash(runtimeType, width, height);

  /// Create a copy of FrameEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$FrameEvent_InitialImplCopyWith<_$FrameEvent_InitialImpl> get copyWith =>
      __$$FrameEvent_InitialImplCopyWithImpl<_$FrameEvent_InitialImpl>(
        this,
        _$identity,
      );

  @override
  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(int width, int height) initial,
    required TResult Function(SharedTextureHandle field0) updated,
    required TResult Function(String field0) failed,
    required TResult Function() idle,
  }) {
    return initial(width, height);
  }

  @override
  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(int width, int height)? initial,
    TResult? Function(SharedTextureHandle field0)? updated,
    TResult? Function(String field0)? failed,
    TResult? Function()? idle,
  }) {
    return initial?.call(width, height);
  }

  @override
  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(int width, int height)? initial,
    TResult Function(SharedTextureHandle field0)? updated,
    TResult Function(String field0)? failed,
    TResult Function()? idle,
    required TResult orElse(),
  }) {
    if (initial != null) {
      return initial(width, height);
    }
    return orElse();
  }

  @override
  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(FrameEvent_Initial value) initial,
    required TResult Function(FrameEvent_Updated value) updated,
    required TResult Function(FrameEvent_Failed value) failed,
    required TResult Function(FrameEvent_Idle value) idle,
  }) {
    return initial(this);
  }

  @override
  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(FrameEvent_Initial value)? initial,
    TResult? Function(FrameEvent_Updated value)? updated,
    TResult? Function(FrameEvent_Failed value)? failed,
    TResult? Function(FrameEvent_Idle value)? idle,
  }) {
    return initial?.call(this);
  }

  @override
  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(FrameEvent_Initial value)? initial,
    TResult Function(FrameEvent_Updated value)? updated,
    TResult Function(FrameEvent_Failed value)? failed,
    TResult Function(FrameEvent_Idle value)? idle,
    required TResult orElse(),
  }) {
    if (initial != null) {
      return initial(this);
    }
    return orElse();
  }
}

abstract class FrameEvent_Initial extends FrameEvent {
  const factory FrameEvent_Initial({
    required final int width,
    required final int height,
  }) = _$FrameEvent_InitialImpl;
  const FrameEvent_Initial._() : super._();

  int get width;
  int get height;

  /// Create a copy of FrameEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$FrameEvent_InitialImplCopyWith<_$FrameEvent_InitialImpl> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class _$$FrameEvent_UpdatedImplCopyWith<$Res> {
  factory _$$FrameEvent_UpdatedImplCopyWith(
    _$FrameEvent_UpdatedImpl value,
    $Res Function(_$FrameEvent_UpdatedImpl) then,
  ) = __$$FrameEvent_UpdatedImplCopyWithImpl<$Res>;
  @useResult
  $Res call({SharedTextureHandle field0});
}

/// @nodoc
class __$$FrameEvent_UpdatedImplCopyWithImpl<$Res>
    extends _$FrameEventCopyWithImpl<$Res, _$FrameEvent_UpdatedImpl>
    implements _$$FrameEvent_UpdatedImplCopyWith<$Res> {
  __$$FrameEvent_UpdatedImplCopyWithImpl(
    _$FrameEvent_UpdatedImpl _value,
    $Res Function(_$FrameEvent_UpdatedImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of FrameEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({Object? field0 = null}) {
    return _then(
      _$FrameEvent_UpdatedImpl(
        null == field0
            ? _value.field0
            : field0 // ignore: cast_nullable_to_non_nullable
                  as SharedTextureHandle,
      ),
    );
  }
}

/// @nodoc

class _$FrameEvent_UpdatedImpl extends FrameEvent_Updated {
  const _$FrameEvent_UpdatedImpl(this.field0) : super._();

  @override
  final SharedTextureHandle field0;

  @override
  String toString() {
    return 'FrameEvent.updated(field0: $field0)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$FrameEvent_UpdatedImpl &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode => Object.hash(runtimeType, field0);

  /// Create a copy of FrameEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$FrameEvent_UpdatedImplCopyWith<_$FrameEvent_UpdatedImpl> get copyWith =>
      __$$FrameEvent_UpdatedImplCopyWithImpl<_$FrameEvent_UpdatedImpl>(
        this,
        _$identity,
      );

  @override
  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(int width, int height) initial,
    required TResult Function(SharedTextureHandle field0) updated,
    required TResult Function(String field0) failed,
    required TResult Function() idle,
  }) {
    return updated(field0);
  }

  @override
  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(int width, int height)? initial,
    TResult? Function(SharedTextureHandle field0)? updated,
    TResult? Function(String field0)? failed,
    TResult? Function()? idle,
  }) {
    return updated?.call(field0);
  }

  @override
  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(int width, int height)? initial,
    TResult Function(SharedTextureHandle field0)? updated,
    TResult Function(String field0)? failed,
    TResult Function()? idle,
    required TResult orElse(),
  }) {
    if (updated != null) {
      return updated(field0);
    }
    return orElse();
  }

  @override
  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(FrameEvent_Initial value) initial,
    required TResult Function(FrameEvent_Updated value) updated,
    required TResult Function(FrameEvent_Failed value) failed,
    required TResult Function(FrameEvent_Idle value) idle,
  }) {
    return updated(this);
  }

  @override
  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(FrameEvent_Initial value)? initial,
    TResult? Function(FrameEvent_Updated value)? updated,
    TResult? Function(FrameEvent_Failed value)? failed,
    TResult? Function(FrameEvent_Idle value)? idle,
  }) {
    return updated?.call(this);
  }

  @override
  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(FrameEvent_Initial value)? initial,
    TResult Function(FrameEvent_Updated value)? updated,
    TResult Function(FrameEvent_Failed value)? failed,
    TResult Function(FrameEvent_Idle value)? idle,
    required TResult orElse(),
  }) {
    if (updated != null) {
      return updated(this);
    }
    return orElse();
  }
}

abstract class FrameEvent_Updated extends FrameEvent {
  const factory FrameEvent_Updated(final SharedTextureHandle field0) =
      _$FrameEvent_UpdatedImpl;
  const FrameEvent_Updated._() : super._();

  SharedTextureHandle get field0;

  /// Create a copy of FrameEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$FrameEvent_UpdatedImplCopyWith<_$FrameEvent_UpdatedImpl> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class _$$FrameEvent_FailedImplCopyWith<$Res> {
  factory _$$FrameEvent_FailedImplCopyWith(
    _$FrameEvent_FailedImpl value,
    $Res Function(_$FrameEvent_FailedImpl) then,
  ) = __$$FrameEvent_FailedImplCopyWithImpl<$Res>;
  @useResult
  $Res call({String field0});
}

/// @nodoc
class __$$FrameEvent_FailedImplCopyWithImpl<$Res>
    extends _$FrameEventCopyWithImpl<$Res, _$FrameEvent_FailedImpl>
    implements _$$FrameEvent_FailedImplCopyWith<$Res> {
  __$$FrameEvent_FailedImplCopyWithImpl(
    _$FrameEvent_FailedImpl _value,
    $Res Function(_$FrameEvent_FailedImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of FrameEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({Object? field0 = null}) {
    return _then(
      _$FrameEvent_FailedImpl(
        null == field0
            ? _value.field0
            : field0 // ignore: cast_nullable_to_non_nullable
                  as String,
      ),
    );
  }
}

/// @nodoc

class _$FrameEvent_FailedImpl extends FrameEvent_Failed {
  const _$FrameEvent_FailedImpl(this.field0) : super._();

  @override
  final String field0;

  @override
  String toString() {
    return 'FrameEvent.failed(field0: $field0)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$FrameEvent_FailedImpl &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode => Object.hash(runtimeType, field0);

  /// Create a copy of FrameEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$FrameEvent_FailedImplCopyWith<_$FrameEvent_FailedImpl> get copyWith =>
      __$$FrameEvent_FailedImplCopyWithImpl<_$FrameEvent_FailedImpl>(
        this,
        _$identity,
      );

  @override
  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(int width, int height) initial,
    required TResult Function(SharedTextureHandle field0) updated,
    required TResult Function(String field0) failed,
    required TResult Function() idle,
  }) {
    return failed(field0);
  }

  @override
  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(int width, int height)? initial,
    TResult? Function(SharedTextureHandle field0)? updated,
    TResult? Function(String field0)? failed,
    TResult? Function()? idle,
  }) {
    return failed?.call(field0);
  }

  @override
  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(int width, int height)? initial,
    TResult Function(SharedTextureHandle field0)? updated,
    TResult Function(String field0)? failed,
    TResult Function()? idle,
    required TResult orElse(),
  }) {
    if (failed != null) {
      return failed(field0);
    }
    return orElse();
  }

  @override
  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(FrameEvent_Initial value) initial,
    required TResult Function(FrameEvent_Updated value) updated,
    required TResult Function(FrameEvent_Failed value) failed,
    required TResult Function(FrameEvent_Idle value) idle,
  }) {
    return failed(this);
  }

  @override
  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(FrameEvent_Initial value)? initial,
    TResult? Function(FrameEvent_Updated value)? updated,
    TResult? Function(FrameEvent_Failed value)? failed,
    TResult? Function(FrameEvent_Idle value)? idle,
  }) {
    return failed?.call(this);
  }

  @override
  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(FrameEvent_Initial value)? initial,
    TResult Function(FrameEvent_Updated value)? updated,
    TResult Function(FrameEvent_Failed value)? failed,
    TResult Function(FrameEvent_Idle value)? idle,
    required TResult orElse(),
  }) {
    if (failed != null) {
      return failed(this);
    }
    return orElse();
  }
}

abstract class FrameEvent_Failed extends FrameEvent {
  const factory FrameEvent_Failed(final String field0) =
      _$FrameEvent_FailedImpl;
  const FrameEvent_Failed._() : super._();

  String get field0;

  /// Create a copy of FrameEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$FrameEvent_FailedImplCopyWith<_$FrameEvent_FailedImpl> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class _$$FrameEvent_IdleImplCopyWith<$Res> {
  factory _$$FrameEvent_IdleImplCopyWith(
    _$FrameEvent_IdleImpl value,
    $Res Function(_$FrameEvent_IdleImpl) then,
  ) = __$$FrameEvent_IdleImplCopyWithImpl<$Res>;
}

/// @nodoc
class __$$FrameEvent_IdleImplCopyWithImpl<$Res>
    extends _$FrameEventCopyWithImpl<$Res, _$FrameEvent_IdleImpl>
    implements _$$FrameEvent_IdleImplCopyWith<$Res> {
  __$$FrameEvent_IdleImplCopyWithImpl(
    _$FrameEvent_IdleImpl _value,
    $Res Function(_$FrameEvent_IdleImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of FrameEvent
  /// with the given fields replaced by the non-null parameter values.
}

/// @nodoc

class _$FrameEvent_IdleImpl extends FrameEvent_Idle {
  const _$FrameEvent_IdleImpl() : super._();

  @override
  String toString() {
    return 'FrameEvent.idle()';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType && other is _$FrameEvent_IdleImpl);
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(int width, int height) initial,
    required TResult Function(SharedTextureHandle field0) updated,
    required TResult Function(String field0) failed,
    required TResult Function() idle,
  }) {
    return idle();
  }

  @override
  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(int width, int height)? initial,
    TResult? Function(SharedTextureHandle field0)? updated,
    TResult? Function(String field0)? failed,
    TResult? Function()? idle,
  }) {
    return idle?.call();
  }

  @override
  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(int width, int height)? initial,
    TResult Function(SharedTextureHandle field0)? updated,
    TResult Function(String field0)? failed,
    TResult Function()? idle,
    required TResult orElse(),
  }) {
    if (idle != null) {
      return idle();
    }
    return orElse();
  }

  @override
  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(FrameEvent_Initial value) initial,
    required TResult Function(FrameEvent_Updated value) updated,
    required TResult Function(FrameEvent_Failed value) failed,
    required TResult Function(FrameEvent_Idle value) idle,
  }) {
    return idle(this);
  }

  @override
  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(FrameEvent_Initial value)? initial,
    TResult? Function(FrameEvent_Updated value)? updated,
    TResult? Function(FrameEvent_Failed value)? failed,
    TResult? Function(FrameEvent_Idle value)? idle,
  }) {
    return idle?.call(this);
  }

  @override
  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(FrameEvent_Initial value)? initial,
    TResult Function(FrameEvent_Updated value)? updated,
    TResult Function(FrameEvent_Failed value)? failed,
    TResult Function(FrameEvent_Idle value)? idle,
    required TResult orElse(),
  }) {
    if (idle != null) {
      return idle(this);
    }
    return orElse();
  }
}

abstract class FrameEvent_Idle extends FrameEvent {
  const factory FrameEvent_Idle() = _$FrameEvent_IdleImpl;
  const FrameEvent_Idle._() : super._();
}
