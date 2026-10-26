/// Helpers for finding the source text that dmd AST nodes were parsed from.
///
/// dmd only records where a node starts (and for binary expressions, where
/// the operator is), so warning ranges are recovered by re-lexing the source.
/// Every function taking `source` expects it to be followed by a 0 byte in
/// memory, as string literals and `BaseAnalyzerDmd.source` are.
module dscanner.analysis.source_range;

import dmd.expression : Expression;
import dmd.tokens : TOK;

/// A token and the byte offsets `[start, end)` it occupies in the source.
struct SourceToken
{
	TOK value;
	size_t start, end;
}

/// Lazily lexes `source` starting at `offset`, ending before the end of file.
auto tokensFrom(const(char)[] source, size_t offset)
{
	import dmd.errorsink : ErrorSinkNull;
	import dmd.globals : global;
	import dmd.lexer : Lexer;

	static struct Tokens
	{
		private Lexer lexer;
		private const(char)* base;

		bool empty() const
		{
			return lexer.token.value == TOK.endOfFile;
		}

		SourceToken front() const
		{
			return SourceToken(lexer.token.value, lexer.token.ptr - base, lexer.p - base);
		}

		void popFront()
		{
			lexer.nextToken();
		}
	}

	__gshared ErrorSinkNull errorSinkNull;
	if (!errorSinkNull)
		errorSinkNull = new ErrorSinkNull;

	auto lexer = new Lexer(null, source.ptr, offset, source.length, false, false, errorSinkNull,
		&global.compileEnv);
	lexer.nextToken();
	return Tokens(lexer, source.ptr);
}

/// The token starting at `offset`.
SourceToken tokenAt(const(char)[] source, size_t offset)
{
	return tokensFrom(source, offset).front;
}

/// The token following the one starting at `offset`.
SourceToken tokenAfter(const(char)[] source, size_t offset)
{
	auto tokens = tokensFrom(source, offset);
	tokens.popFront();
	return tokens.front;
}

/**
 * Start offset of the declaration whose name is at `nameOffset`: the first
 * token after the preceding `{`, `}`, `;` or `:`, so return types and
 * attributes are included.
 */
size_t declarationStart(const(char)[] source, size_t nameOffset)
{
	import std.string : lastIndexOfAny;

	const separator = source[0 .. nameOffset].lastIndexOfAny("{};:");
	return tokenAt(source, separator + 1).start;
}

/// End offset of the qualified name `a.b.c` starting at `offset`.
size_t qualifiedNameEnd(const(char)[] source, size_t offset)
{
	size_t end = offset;
	bool expectIdentifier = true;
	foreach (token; tokensFrom(source, offset))
	{
		if (token.value != (expectIdentifier ? TOK.identifier : TOK.dot))
			break;
		if (expectIdentifier)
			end = token.end;
		expectIdentifier = !expectIdentifier;
	}
	return end;
}

/// The first token of kind `value` at or after `offset`, or a token of kind
/// `TOK.endOfFile` when there is none.
SourceToken findToken(const(char)[] source, size_t offset, TOK value)
{
	return firstToken(source, offset, (SourceToken token) => token.value == value);
}

/// The first identifier spelled `name` at or after `offset`, or a token of
/// kind `TOK.endOfFile` when there is none.
SourceToken findIdentifier(const(char)[] source, size_t offset, const(char)[] name)
{
	return firstToken(source, offset,
		(SourceToken token) => token.value == TOK.identifier && source[token.start .. token.end] == name);
}

private SourceToken firstToken(const(char)[] source, size_t offset, scope bool delegate(SourceToken) matches)
{
	foreach (token; tokensFrom(source, offset))
		if (matches(token))
			return token;
	return SourceToken(TOK.endOfFile, source.length, source.length);
}

/**
 * End offset of the code that starts at `start` and whose last token starts
 * at `lastTokenStart`. Brackets opened in between are followed to their
 * closing token, so `[1, 2, 3]` ends after `]` although dmd only records `3`.
 */
size_t balancedEnd(const(char)[] source, size_t start, size_t lastTokenStart)
{
	size_t depth;
	foreach (token; tokensFrom(source, start))
	{
		if (isOpening(token.value))
			depth++;
		else if (isClosing(token.value) && depth > 0)
			depth--;

		if (token.start >= lastTokenStart && depth == 0)
			return token.end;
	}
	return source.length;
}

private bool isOpening(TOK value)
{
	return value == TOK.leftParenthesis || value == TOK.leftBracket || value == TOK.leftCurly;
}

private bool isClosing(TOK value)
{
	return value == TOK.rightParenthesis || value == TOK.rightBracket || value == TOK.rightCurly;
}

/// 1-based lines and byte columns of a `[start, end)` offset pair.
struct SourcePositions
{
	size_t[2] lines, columns;
}

/// ditto
SourcePositions positionsOf(const(char)[] source, size_t[2] offsets)
{
	import std.algorithm : count;
	import std.string : lastIndexOf;

	SourcePositions positions;
	foreach (i, offset; offsets)
	{
		const before = source[0 .. offset];
		positions.lines[i] = before.count('\n') + 1;
		positions.columns[i] = offset - (before.lastIndexOf('\n') + 1) + 1;
	}
	return positions;
}

/// `[start, end)` offsets of the source text `expression` was parsed from.
size_t[2] extentOf(const(char)[] source, Expression expression)
{
	import dmd.visitor : StoppableVisitor;
	import dmd.visitor.postorder : walkPostorder;

	extern (C++) static final class LocationBounds : StoppableVisitor
	{
		alias visit = typeof(super).visit;
		const(char)[] source;
		size_t first = size_t.max, last;

		extern (D) this(const(char)[] source)
		{
			this.source = source;
		}

		override void visit(Expression e)
		{
			const offset = e.loc.fileOffset;
			if (offset < first)
				first = offset;
			// the identifier of `a.b` has no location of its own
			const lastOffset = e.isDotIdExp()
				? tokenAfter(source, findToken(source, extentOf(source, e.isDotIdExp().e1)[1], TOK.dot).start).start
				: offset;
			if (lastOffset > last)
				last = lastOffset;
		}
	}

	scope bounds = new LocationBounds(source);
	walkPostorder(expression, bounds);
	return [bounds.first, balancedEnd(source, bounds.first, bounds.last)];
}

unittest
{
	import std.algorithm : map;
	import std.array : array;

	enum source = "int[] a = [1, (2 + 3)];\nfoo(a);";
	assert(tokensFrom(source, 0).map!(t => source[t.start .. t.end]).array
		== ["int", "[", "]", "a", "=", "[", "1", ",", "(", "2", "+", "3", ")", "]", ";",
			"foo", "(", "a", ")", ";"]);
	assert(tokenAt(source, 6) == SourceToken(TOK.identifier, 6, 7));
	assert(tokenAfter(source, 6) == SourceToken(TOK.assign, 8, 9));
	assert(findToken(source, 0, TOK.semicolon) == SourceToken(TOK.semicolon, 22, 23));
	assert(findToken(source, 30, TOK.assign).value == TOK.endOfFile);
	assert(findIdentifier(source, 0, "foo") == SourceToken(TOK.identifier, 24, 27));
	assert(balancedEnd(source, 10, 11) == 22);
	assert(declarationStart("struct S { /// doc\n\t@safe bool empty(); }", 30) == 20);
	assert(qualifiedNameEnd("import a.bc.d : x;", 7) == 13);
	assert(positionsOf(source, [10, 27]) == SourcePositions([1, 2], [11, 4]));
}
