/**
 * This whole package is used for the declarative model descriptions. The
 * declarative descriptions are automatically generated from the D source code
 * and are used for the diff process for the migrations generator.
 *
 * The conversion from D classes/structs + UDAs into the declarative format
 * described in this module is done inside the $(REF conversion, dorm,declarative)
 * module.
 */
module dorm.declarative;

import dorm.annotations;
import dorm.model;

import std.algorithm;
import std.array;
import std.sumtype;
import std.typecons : tuple;

import mir.serde;
import mir.algebraic_alias.json;

/**
 * This is the root of a described models module. It contains a list of models
 * as defined in the D source file.
 *
 * The `validators` and `valueConstructors` maps contain the global functions
 * defined in the $(REF defaultValue, dorm,annotations) and $(REF validator,
 * dorm,annotations) UDAs.
 */
struct SerializedModels
{
	/// List of all the models defined in the full module file.
	@serdeKeys("Models")
	ModelFormat[] models;
}

/** 
 * Describes a single Model class (Database Table) in a generic format that is
 * only later used by the drivers to actually convert to SQL statements.
 */
struct ModelFormat
{
	/** 
	 * Describes a field inside the Model class, which corresponds to a column
	 * inside the actual database table later. It's using a generic format that
	 * is only later used by the drivers to actually convert to SQL statements.
	 */
	struct Field
	{
		/// List of different (generic) database column types.
		@serdeProxy!string
		enum DBType
		{
			varchar, /// inferred from `string`
			varbinary, /// inferred from `ubyte[]`
			int8, /// inferred from `byte`
			int16, /// inferred from `short`
			int32, /// inferred from `int`
			int64, /// inferred from `long`
			uint8, /// inferred from `ubyte`
			uint16, /// inferred from `ushort`
			uint32, /// inferred from `uint`
			uint64, /// inferred from `ulong`
			floatNumber, /// inferred from `float`
			doubleNumber, /// inferred from `double`
			boolean, /// inferred from `bool`
			date, /// inferred from `std.datetime : Date`
			datetime, /// inferred from `std.datetime : DateTime`
			timestamp, /// inferred from `std.datetime : SysTime`, `@AutoCreateTime ulong`, `@AutoUpdateTime ulong`, `@timestamp ulong`
			time, /// inferred from `std.datetime : TimeOfDay`
			choices, /// inferred from `@choices string`, `enum T : string`
			set, /// inferred from `BitFlags!enum`
			not_null, /// everything that is not $(REF Nullable, std,typecons) or a Model that is not marked @notNull
		}

		/// The exact name of the column later used in the DB, not neccessarily
		/// corresponding to the D field name anymore.
		@serdeKeys("Name")
		string name;
		/// The generic column type that is later translated to a concrete SQL
		/// type by a driver.
		@serdeKeys("Type")
		DBType type;
		/// List of different annotations defined in the source code, converted
		/// to a serializable format and also all implicit annotations such as
		/// `Choices` for enums.
		@serdeKeys("Annotations")
		DBAnnotation[] annotations;
		/// List of annotations only relevant for internal use.
		@serdeIgnore
		InternalAnnotation[] internalAnnotations;
		/// For debugging purposes this is the D source code location where this
		/// field is defined from. This can be used in error messages.
		@serdeKeys("SourceDefinedAt")
		SourceLocation definedAt;
	}

	/// The exact name of the table later used in the DB, not neccessarily
	/// corresponding to the D class name anymore.
	@serdeKeys("Name")
	string name;
	/// For debugging purposes this is the D source code location where this
	/// field is defined from. This can be used in error messages.
	@serdeKeys("SourceDefinedAt")
	SourceLocation definedAt;
	/// List of fields, such as defined in the D source code, recursively
	/// including all fields from all inherited classes. This maps to the actual
	/// SQL columns later when it is generated into an SQL create statement by
	/// the actual driver implementation.
	@serdeKeys("Fields")
	Field[] fields;
}

/**
 * The source location where something is defined in D code.
 *
 * The implementation uses [__traits(getLocation)](https://dlang.org/spec/traits.html#getLocation)
 */
struct SourceLocation
{
	/// The D filename, assumed to be of the same format as [__FILE__](https://dlang.org/spec/expression.html#specialkeywords).
	@serdeKeys("File")
	string sourceFile;
	/// The 1-based line number and column number where the symbol is defined.
	@serdeKeys("Line")
	int sourceLine;
	/// ditto
	@serdeKeys("Column")
	int sourceColumn;
}

/**
 * This enum contains all no-argument flags that can be added as annotation to
 * the fields. It's part of the $(LREF DBAnnotation) SumType.
 */
enum AnnotationFlag
{
	/// corresponds to the $(REF autoCreateTime, dorm,annotations) UDA.
	autoCreateTime,
	/// corresponds to the $(REF autoUpdateTime, dorm,annotations) UDA.
	autoUpdateTime,
	/// corresponds to the $(REF autoincrement, dorm,annotations) UDA.
	autoincrement,
	/// corresponds to the $(REF primaryKey, dorm,annotations) UDA.
	primaryKey,
	/// corresponds to the $(REF unique, dorm,annotations) UDA.
	unique,
	/// corresponds to the $(REF notNull, dorm,annotations) UDA. Implicit for all types except Nullable!T and Model.
	notNull
}

/**
 * SumType combining all the different annotations (UDAs) that can be added to
 * a model field, in a serializable format. (e.g. the lambdas are moved into a
 * helper field in the model description and these annotations only contain an
 * integer to reference it)
 */
@serdeProxy!IonDBAnnotation
struct DBAnnotation
{
	SumType!(
		AnnotationFlag,
		maxLength,
		PossibleDefaultValueTs,
		Choices,
		index
	) value;
	alias value this;

	this(T)(T v)
	{
		value = v;
	}

	auto opAssign(T)(T v)
	{
		value = v;
		return this;
	}
}

alias InternalAnnotation = SumType!(ConstructValueRef, ValidatorRef);

private struct IonDBAnnotation
{
	JsonAlgebraic data;

	this(DBAnnotation a)
	{
		a.match!(
			(AnnotationFlag f) {
				string typeStr;
				final switch (f)
				{
					case AnnotationFlag.autoCreateTime:
						typeStr = "auto_create_time";
						break;
					case AnnotationFlag.autoUpdateTime:
						typeStr = "auto_update_time";
						break;
					case AnnotationFlag.notNull:
						typeStr = "not_null";
						break;
					case AnnotationFlag.autoincrement:
						typeStr = "autoincrement";
						break;
					case AnnotationFlag.primaryKey:
						typeStr = "primary_key";
						break;
					case AnnotationFlag.unique:
						typeStr = "unique";
						break;
				}
				data = JsonAlgebraic([
					"Type": JsonAlgebraic(typeStr)
				]);
			},
			(maxLength l) {
				data = JsonAlgebraic([
					"Type": JsonAlgebraic("max_length"),
					"Value": JsonAlgebraic(l.maxLength)
				]);
			},
			(Choices c) {
				data = JsonAlgebraic([
					"Type": JsonAlgebraic("max_length"),
					"Value": JsonAlgebraic(c.choices.map!(v => JsonAlgebraic(v)).array)
				]);
			},
			(index i) {
				JsonAlgebraic[string] args;
				if (i._composite !is i.composite.init)
					args["Name"] = i._composite.name;
				if (i._priority !is i.priority.init)
					args["Priority"] = i._priority.priority;

				if (args.empty)
					data = JsonAlgebraic(["Type": JsonAlgebraic("index")]);
				else
					data = JsonAlgebraic([
						"Type": JsonAlgebraic("index"),
						"Value": JsonAlgebraic(args)
					]);
			},
			(DefaultValue!(ubyte[]) binary) {
				import std.digest : toHexString;

				data = JsonAlgebraic([
					"Type": JsonAlgebraic("default"),
					"Value": JsonAlgebraic(binary.value.toHexString)
				]);
			},
			(rest) {
				static assert(is(typeof(rest) == DefaultValue!U, U));
				static if (__traits(hasMember, rest.value, "toISOExtString"))
				{
					data = JsonAlgebraic([
						"Type": JsonAlgebraic("default"),
						"Value": JsonAlgebraic(rest.value.toISOExtString)
					]);
				}
				else
				{
					data = JsonAlgebraic([
						"Type": JsonAlgebraic("default"),
						"Value": JsonAlgebraic(rest.value)
					]);
				}
			}
		);
	}

	void serialize(S)(scope ref S serializer) const
	{
		import mir.ser : serializeValue;

		serializeValue(serializer, data);
	}
}

/**
 * Corresponds to the $(REF constructValue, dorm,annotations) and $(REF
 * constructValue, dorm,annotations) UDAs.
 *
 * A global function that is compiled into the executable through the call of
 * $(REF processModelsToDeclarations, dorm,declarative) generating the
 * `InternalAnnotation` values. Manually constructing this function is not
 * required, use the $(REF RegisterModels, dorm,declarative,entrypoint) mixin
 * instead.
 *
 * The functions take in a Model (class) instance and assert it is the correct
 * model class type that it was registered with.
 */
struct ConstructValueRef
{
	/*
	 * This function calls the UDA specified lambda without argument and
	 * sets the annotated field value inside the containing Model instance to
	 * its return value, with the code assuming it can simply assign it.
	 * (a compiler error will occur if it cannot implicitly convert to the
	 * annotated property type)
	 */
	void function(Model) callback;
}

/// ditto
struct ValidatorRef
{
	/*
	 * This function calls the UDA specified lambda with the field as argument
	 * and returns its return value, with the code assuming it is a boolean.
	 * (a compiler error will occur if it cannot implicitly convert to `bool`)
	 */
	bool function(Model) callback;
}

unittest
{
	import mir.ser.json;

	SerializedModels models;
	ModelFormat m;
	m.name = "foo";
	m.definedAt = SourceLocation("file.d", 140, 10);
	ModelFormat.Field f;
	f.name = "foo";
	f.type = ModelFormat.Field.DBType.varchar;
	f.definedAt = SourceLocation("file.d", 142, 12);
	f.annotations = [
		DBAnnotation(AnnotationFlag.primaryKey),
		DBAnnotation(AnnotationFlag.notNull),
		DBAnnotation(index()),
		DBAnnotation(maxLength(255))
	];
	f.internalAnnotations = [
		InternalAnnotation(ValidatorRef(m => true))
	];
	m.fields = [f];

	models.models = [m];
	string json = serializeJsonPretty(models);
	assert(json == `{
	"Models": [
		{
			"Name": "foo",
			"SourceDefinedAt": {
				"File": "file.d",
				"Line": 140,
				"Column": 10
			},
			"Fields": [
				{
					"Name": "foo",
					"Type": "varchar",
					"Annotations": [
						{
							"Type": "primary_key"
						},
						{
							"Type": "not_null"
						},
						{
							"Type": "index"
						},
						{
							"Type": "max_length",
							"Value": 255
						}
					],
					"SourceDefinedAt": {
						"File": "file.d",
						"Line": 142,
						"Column": 12
					}
				}
			]
		}
	]
}`, json);
}
