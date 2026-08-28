import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:player/presentation/screens/calendar/calendar_screen.dart';

void main() {
  group('isCalendarUnsupported', () {
    test('recognises the server rejecting the calendar root field', () {
      final exception = OperationException(
        graphqlErrors: [
          const GraphQLError(
            message: 'Cannot query field "calendar" on type "RootQueryType".',
          ),
        ],
      );

      expect(isCalendarUnsupported(exception), isTrue);
    });

    test('does not claim an ordinary error is a version problem', () {
      final exception = OperationException(
        graphqlErrors: [const GraphQLError(message: 'Not authenticated')],
      );

      expect(isCalendarUnsupported(exception), isFalse);
    });

    test('does not claim a transport failure is a version problem', () {
      final exception = OperationException(
        linkException: NetworkException(
          originalException: Exception('connection refused'),
          message: 'connection refused',
          uri: Uri.parse('https://example.invalid/graphql'),
        ),
      );

      expect(isCalendarUnsupported(exception), isFalse);
    });

    test('is false for an error that is not a GraphQL exception at all', () {
      expect(isCalendarUnsupported(StateError('boom')), isFalse);
    });
  });
}
