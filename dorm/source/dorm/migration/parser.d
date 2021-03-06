module dorm.migration.parser;

import core.exception;

import std.algorithm;
import std.array;
import std.conv;
import std.file;
import std.meta;
import std.path;
import std.stdio;
import std.sumtype;
import std.traits;

import dorm.annotations;
import dorm.declarative;
import dorm.exceptions;
import dorm.migration.declaration;

import toml;

alias exactly(T, alias fun) = function(arg) {
    static assert(is(typeof(arg) == T));
    return fun(arg);
};

alias oneOf(alias fun, T...) = function(arg) {
    static assert(staticIndexOf!(typeof(arg), T) != -1);
    return fun(arg);
};

/** 
 * Helper function to check if a parameter exists in the given table
 * and is of the desired type.
 * 
 * Params:
 *   keyName = Key to search for
 *   table   = Reference to map of string : TOMLValue to search in
 *   type    = Desired type
 *   path    = Path to migration file, used for exceptions
 *
 * Throws: dorm.exceptions.MigrationException if key was not
 *      found or has the wrong type
 */
void checkValueExists(
    string keyName, ref TOMLValue[string] table, TOML_TYPE type, string path
)
{
    if ((keyName in table) is null)
    {
        throw new MigrationException(
            "missing key " ~ keyName ~ " of type "
                ~ type.to!string ~ " in migration file " ~ path
        );
    }

    if (table[keyName].type != type)
    {
        throw new MigrationException(
            "key " ~ keyName ~ " is of the wrong type. Should be of type "
                ~ to!string(
                    type) ~ ". Is " ~ to!string(table[keyName].type)
                ~ ". Migration file " ~ path
        );

    }
}

/** 
 * Helper function to parse migration files.
 * 
 * Params:
 *   path = Path to the file that should be parsed
 *
 * Returns: Migration
 *
 * Throws: dorm.exceptions.MigrationException
 */
Migration parseFile(string path)
{
    void[] data;
    try
    {
        data = read(path);
    }
    catch (FileException exc)
    {
        throw new MigrationException(
            "could not read migration file: " ~ path, exc
        );
    }

    try
    {
        auto doc = parseTOML(cast(string) data);

        Migration migration;

        migration.id = baseName(path)[0 .. $ - 5];

        checkValueExists("Migration", doc.table, TOML_TYPE.TABLE, path);
        TOMLValue migrationSection = doc.table["Migration"];

        checkValueExists("Hash", migrationSection.table, TOML_TYPE.INTEGER, path);
        migration.hash = migrationSection.table["Hash"].integer;

        checkValueExists("Initial", migrationSection.table, TOML_TYPE.BOOL, path);
        migration.initial = migrationSection.table["Initial"].boolean;

        checkValueExists("Dependency", migrationSection.table, TOML_TYPE.STRING, path);
        migration.dependency = migrationSection.table["Dependency"].str;

        // dfmt off

        checkValueExists("Replaces", migrationSection.table, TOML_TYPE.ARRAY, path);
        TOMLValue[] replaces = migrationSection.table["Replaces"].array;
        replaces.each!((TOMLValue x) {
            if (x.type != TOML_TYPE.STRING)
            {
                throw new MigrationException(
                    "type of Migration.Replaces member is wrong. Expected: "
                    ~ to!string(TOML_TYPE.STRING) ~ ". Found "
                    ~ to!string(x.type) ~ "Migration file: " ~ path
                );
            }
            migration.replaces ~= x.str;
        });

        checkValueExists("Operations", migrationSection.table, TOML_TYPE.ARRAY, path);
        TOMLValue[] operations = migrationSection.table["Operations"].array;
        operations.each!(
            (TOMLValue x) {
            checkValueExists("Type", x.table, TOML_TYPE.STRING, path);
            string type = x.table["Type"].str;

            switch (type)
            {
            case "CreateModel":
                CreateModelOperation createModelOperation;

                checkValueExists("Name", x.table, TOML_TYPE.STRING, path);
                createModelOperation.name = x.table["Name"].str;

                // As there must be at least one column to create a table,
                // we can check for this at well

                checkValueExists("Fields", x.table, TOML_TYPE.ARRAY, path);
                if (x.table["Fields"].array.length == 0)
                {
                    throw new MigrationException(
                        "There must be at least one field. Migration file: " 
                            ~ path
                    );
                }
                createModelOperation.fields = x.table["Fields"].array.map!(
                    (y) {
                        Field f;
                        checkValueExists("Name", y.table, TOML_TYPE.STRING, path);
                        f.name = y.table["Name"].str;

                        checkValueExists("Type", y.table, TOML_TYPE.STRING, path);
                        try 
                        {
                            f.type = y.table["Type"].str.to!DBType;
                        }
                        catch (ConvException exc)
                        {
                            throw new MigrationException(
                                "Found unknown DBType: " ~ y.table["Type"].str,
                                exc
                            );
                        }

                        checkValueExists("Annotations", y.table, TOML_TYPE.ARRAY, path);
                        f.annotations = y.table["Annotations"].array.map!(
                            (z) {
                                Annotation a;
                                checkValueExists("Type", z.table, TOML_TYPE.STRING, path);
                                a.type = z.table["Type"].str;
                                if (annotationsWithoutValue.canFind(z.table["Type"].str))
                                {
                                    // Empty case to check if the key is known
                                }
                                else if (annotationsWithValue.canFind(z.table["Type"].str))
                                {
                                    a.value = TOMLToAnnotationType(z.table["Value"]);
                                }
                                else {
                                    throw new MigrationException(
                                        "Unknwon type " ~ a.type
                                        ~ " in Migration file " ~ path
                                    );
                                }

                                return a;
                            }
                        ).array;

                        return f;
                    }
                ).array;

                migration.operations ~= OperationType(createModelOperation);

                break;
            
            case "DeleteModel":
                checkValueExists("Name", x.table, TOML_TYPE.STRING, path);

                migration.operations ~= OperationType(
                    DeleteModelOperation(x.table["Name"].str)
                );
                break;
            
            case "AddField":
                checkValueExists("Name", x.table, TOML_TYPE.STRING, path);

                checkValueExists("Field", x.table, TOML_TYPE.TABLE, path);

                TOMLValue[string] f = x.table["Field"].table;
                Field field;

                checkValueExists("Name", f, TOML_TYPE.STRING, path);
                field.name = f["Name"].str;

                checkValueExists("Type", f, TOML_TYPE.STRING, path);
                try 
                {
                    field.type = f["Type"].str.to!DBType;
                }
                catch (ConvException exc)
                {
                    throw new MigrationException(
                        "Found unknown DBType: " ~ f["Type"].str, exc
                    );
                }

                checkValueExists("Annotations", f, TOML_TYPE.ARRAY, path);
                field.annotations = f["Annotations"].array.map!(
                    (z) {
                        Annotation a;
                        checkValueExists("Type", z.table, TOML_TYPE.STRING, path);
                        a.type = z.table["Type"].str;
                        if (annotationsWithoutValue.canFind(z.table["Type"].str))
                        {
                            // Empty case to check if the key is known
                        }
                        else if (annotationsWithValue.canFind(z.table["Type"].str))
                        {
                            a.value = TOMLToAnnotationType(z.table["Value"]);
                        }
                        else {
                            throw new MigrationException(
                                "Unknwon type " ~ a.type
                                ~ " in Migration file " ~ path
                            );
                        }

                        return a;
                    }
                ).array;

                migration.operations ~= OperationType(
                    AddFieldOperation(x.table["Name"].str, field)
                );

                break;
            
            case "DeleteField":
                checkValueExists("Name", x.table, TOML_TYPE.STRING, path);

                checkValueExists("Field", x.table, TOML_TYPE.TABLE, path);
                TOMLValue[string] field = x.table["Field"].table;

                checkValueExists("Name", field, TOML_TYPE.STRING, path);
                
                migration.operations ~= OperationType(
                    DeleteFieldOperation(
                        x.table["Name"].str, field["Name"].str
                    )
                );
                break;
                
            // If type is not known, throw
            default:
                throw new MigrationException(
                    "operation type " ~ type ~ " is unknown"
                );
            }

        }
        );

        //dfmt on
        // TODO: Implement operations

        return migration;
    }

    catch (TOMLParserException exc)
    {
        throw new MigrationException(
            "could not parse migration file " ~ path, exc
        );
    }
}

unittest
{
    import std.path;

    string test = `
    [Migration]
    Hash = 1203019591923
    Initial = true
    Dependency = "01"
    Replaces = ["01_old"]

    [[Migration.Operations]]
    Name = "Foo"
    Type = "CreateModel"
    
    [[Migration.Operations.Fields]]
    Name = "id"
    Type = "uint64"

    [[Migration.Operations.Fields.Annotations]]
    Type = "NotNull"
    `;

    auto fh = File(buildPath(tempDir(), "dormmigrationtest.toml"), "w");
    scope (exit)
    {
        remove(fh.name());
    }

    fh.writeln(test);
    fh.close();

    auto correct = Migration(
        1203019591923, // @suppress(dscanner.style.number_literals)
        true, "3", "01", ["01_old"], [
            OperationType(CreateModelOperation(
                "Foo", [Field("id", DBType.uint64, [Annotation("NotNull")])]
            ))
        ]
    );
    auto toTest = parseFile(fh.name());
    assert(correct.dependency == toTest.dependency);
    assert(correct.operations == toTest.operations);
    assert(correct.replaces == toTest.replaces);
    assert(correct.initial == toTest.initial);
    assert(correct.hash == toTest.hash);
}

/** 
 * Helper function to serialize a field.
 *
 * Params:
 *   field = Field to serialize
 *
 * Returns: TOMLValue with type table
 */
TOMLValue serializeField(ref Field field)
{
    TOMLValue[string] fieldTable;
    fieldTable["Name"] = TOMLValue(field.name);
    fieldTable["Type"] = TOMLValue(to!string(field.type));

    // dfmt off
    TOMLValue annotationToTOML(AnnotationType at)
    {
        return at.match!(
            (AnnotationType[] v) => TOMLValue(v.map!(z => annotationToTOML(z)).array),
            (AnnotationType[string] v) {
                TOMLValue[string] table;
                foreach (key, value; v)
                {
                    table[key] = annotationToTOML(value);
                }
                return TOMLValue(table);
            },
            v => TOMLValue(v)
        );
    }

    fieldTable["Annotations"] = TOMLValue(field.annotations.map!(
        (Annotation x) {
            TOMLValue[string] table;
            table["Type"] = x.type;
            if (annotationsWithValue.canFind(x.type))
                table["Value"] = annotationToTOML(x.value);
            
            return TOMLValue(table);
        }
    ).array);
    // dfmt on

    return TOMLValue(fieldTable);
}

/** 
 * Helper function to serialize a migration.
 *
 * Params:
 *   migration = Reference to a valid migration object
 *
 * Returns: serialized string
 */
string serializeMigration(ref Migration migration)
{
    auto doc = TOMLDocument();

    TOMLValue[string] migTable;

    migTable["Hash"] = TOMLValue(migration.hash);
    migTable["Initial"] = TOMLValue(migration.initial);
    migTable["Dependency"] = TOMLValue(migration.dependency);
    migTable["Replaces"] = TOMLValue(migration.replaces.map!(
            x => TOMLValue(x)
    ).array);

    // dfmt off
    migTable["Operations"] = TOMLValue(migration.operations.map!(
        x => x.match!(
            // Case of CreateModeCreation
            (CreateModelOperation y) {
                TOMLValue[string] operationTable;
                operationTable["Type"] = "CreateModel";
                operationTable["Name"] = y.name;
                operationTable["Fields"] = y.fields.map!(
                    z => serializeField(z)
                ).array;
                return operationTable;
            },
            (DeleteModelOperation y) {
                TOMLValue[string] operationTable;
                operationTable["Type"] = "DeleteModel";
                operationTable["Name"] = y.name;
                return operationTable;
            },
            (AddFieldOperation y) {
                TOMLValue[string] operationTable;
                operationTable["Type"] = "AddField";
                operationTable["Name"] = y.name;
                operationTable["Field"] = serializeField(y.field);
                return operationTable;
            },
            (DeleteFieldOperation y) {
                TOMLValue[string] operationTable;
                operationTable["Type"] = "DeleteField";
                operationTable["Name"] = y.modelName;
                TOMLValue[string] fieldTable;
                fieldTable["Name"] = y.fieldName;
                operationTable["Field"] = fieldTable;
                return operationTable;
            }
        )
    ).array);
    // dfmt on

    doc.table["Migration"] = TOMLValue(migTable);

    return doc.toString();
}

unittest
{
    import std.typecons;

    alias DBType = ModelFormat.Field.DBType;

    auto tests = [
        tuple(
            Migration(
                123,
                true,
                "0001",
                [],
                ["0001_old_initial"],
                [
                    OperationType(
                    CreateModelOperation(
                    "test_model",
                    [
                        Field("id", DBType.uint64, [
                            Annotation("PrimaryKey"),
                            Annotation("NotNull")
                        ])
                    ]
                    )
                    )
                ]
        ),
        ""
        )
    ];

    foreach (test; tests)
    {
        auto toTest = serializeMigration(test[0]);
        //assert(test[1] == serializeMigration(test[0]));
    }

    //TODO: How to test?
}

/** 
 * Helper function to convert a DBAnnotation to 
 * AnnotationType defined in migrations
 * 
 * Params:
 *   annotation = DBAnnotation from SerializedModel.models.fields.annotations
 *
 * Returns: Converted Annotation
 */
Annotation serializedAnnotationToAnnotation(ref DBAnnotation annotation)
{
    //dfmt off

    return annotation.match!(
        // Annotation flag
        (AnnotationFlag y) => Annotation(y.to!string),

        // maxLength
        (maxLength y) => Annotation("MaxLength", AnnotationType(y.maxLength)),

        // PossibleDefaultValueTs
        oneOf!((allPossibleValues) {
            return Annotation("DefaultValue", AnnotationType(allPossibleValues.value));
        }, PossibleDefaultValueTs),

        // Choices
        (Choices y) => Annotation("Choices", AnnotationType(y.choices.map!(
            z => AnnotationType(z.to!string)
        ).array)),

        // index
        (index y) {
            auto table = cast(AnnotationType[string])[
                "Priority": AnnotationType(y._priority.priority),
            ];
            if (y._composite.name.length > 0) {
                table["Name"] = y._composite.name;
            }
            
            return Annotation("Index", AnnotationType(table));
        }
    );

    //dfmt on
}

/** 
 * Helper function to convert a Field to a ModelFormat.Field
 *
 * Params:
 *   field = Field parsed by TOML parser
 *
 * Returns: ModelFormat.Field
 */
ModelFormat.Field fieldToModelFormatField(ref Field field)
{
    ModelFormat.Field f;

    f.name = field.name;
    f.type = field.type;

    foreach (annotation; field.annotations)
    {
        switch (annotation.type)
        {
        case "NotNull":
            f.annotations ~= DBAnnotation(
                AnnotationFlag.notNull
            );
            break;
        case "AutoUpdateTime":
            f.annotations ~= DBAnnotation(
                AnnotationFlag.autoUpdateTime
            );
            break;
        case "AutoCreateTime":
            f.annotations ~= DBAnnotation(
                AnnotationFlag.autoCreateTime
            );
            break;
        case "PrimaryKey":
            f.annotations ~= DBAnnotation(
                AnnotationFlag.primaryKey
            );
            break;
        case "Unique":
            f.annotations ~= DBAnnotation(
                AnnotationFlag.unique
            );
            break;
        case "Choices":
            string[] choices;

            // dfmt off
            annotation.value.match!(
                (AnnotationType[] arr) {
                    arr.each!(x => x.match!(
                        (string c) { choices ~= c; },
                        (_) {
                            throw new MigrationException(
                                "Choices value element is not of type string"
                            );
                        }
                    ));
                },
                (_) {
                    throw new MigrationException(
                        "Choices are not of type string[]"
                    );
                }
            );
            // dfmt on

            f.annotations ~= DBAnnotation(Choices(choices));
            break;
        case "DefaultValue":
            // dfmt off
            annotation.value.match!(
                (AnnotationType[]) {
                    throw new MigrationException(
                        "Array is not allowed as DefaultValue annotation"
                    );
                },
                (AnnotationType[string]) {
                    throw new MigrationException(
                        "Map is not allowed as DefaultValue annotation"
                    );
                },
                (v) {
                    f.annotations ~= DBAnnotation(
                        defaultValue(v)
                    );
                }
            );
            // dfmt on
            break;
        case "Index":
            // TODO: Check how to convert to indexes
            f.annotations ~= DBAnnotation();
            break;
        case "MaxLength":
            int length;

            // dfmt off
            annotation.value.match!(
                (long l) { length = l.to!int; },
                (_) {
                    throw new MigrationException(
                        "MaxLength's value is not of type int"
                    );
                }
            );
            // dfmt on

            f.annotations ~= DBAnnotation(
                maxLength(length)
            );
            break;
        default:
            throw new MigrationException(
                "Got unknown AnnotationType: " ~ annotation.type
            );
        }
    }

    return f;
}

/** 
 * Helper function to generate the correct AnnotationType from
 * the TOMLValue "Value"
 * 
 * Params:
 *   value = Migration.Operations.Fields.Annotations.Value as TOMLValue
 *
 * Returns: 
 */
AnnotationType TOMLToAnnotationType(ref TOMLValue value) // @suppress(dscanner.style.phobos_naming_convention)
{
    final switch (value.type)
    {
    case TOML_TYPE.BOOL:
        return AnnotationType(value.boolean);
    case TOML_TYPE.STRING:
        return AnnotationType(value.str);
    case TOML_TYPE.FLOAT:
        return AnnotationType(value.floating);
    case TOML_TYPE.INTEGER:
        return AnnotationType(value.integer);
    case TOML_TYPE.LOCAL_DATE:
        return AnnotationType(value.localDate);
    case TOML_TYPE.LOCAL_DATETIME:
        return AnnotationType(value.localDatetime);
    case TOML_TYPE.LOCAL_TIME:
        return AnnotationType(value.localTime);
    case TOML_TYPE.OFFSET_DATETIME:
        return AnnotationType(value.offsetDatetime);
    case TOML_TYPE.ARRAY:
        return AnnotationType(value.array.map!(
                x => TOMLToAnnotationType(x)
        ).array);
    case TOML_TYPE.TABLE:
        AnnotationType[string] ret;
        foreach (key, v; value.table)
        {
            ret[key] = TOMLToAnnotationType(v);
        }
        return AnnotationType(ret);

    }
}

/** 
 * Helper function to convert a list of ordered, validated migrations
 * to generate a single SerializedModels object.
 * 
 * Params:
 *   ordered = List of ordered, validated migrations
 *
 * Throws: dorm.exceptions.MigrationException
 *
 * Returns: SerializedModels
 */
SerializedModels migrationsToSerializedModels(ref Migration[] ordered)
{
    SerializedModels sm;

    // dfmt off
    ordered.each!(
        x => x.operations.each!(
            (y) { 
                y.match!(
                    (CreateModelOperation cmo) {
                        ModelFormat mf;

                        mf.name = cmo.name;
                        mf.fields = cmo.fields.map!(
                            z => fieldToModelFormatField(z)
                        ).array;

                        sm.models ~= mf;
                    },
                    (DeleteModelOperation dmo) {
                        sm.models = sm.models.remove!(
                            x => x.name == dmo.name
                        );
                    },
                    (AddFieldOperation afo) {
                        sm.models.each!(
                            (ref ModelFormat z) {
                                if (z.name == afo.name)
                                {
                                    z.fields ~= fieldToModelFormatField(
                                        afo.field
                                    );
                                }
                            }
                        );
                    },
                    (DeleteFieldOperation dfo) {
                        sm.models.each!(
                            (ref ModelFormat z) {
                                if (z.name == dfo.modelName)
                                {
                                    z.fields = z.fields.filter!(
                                        a => a.name != dfo.fieldName
                                    ).array;
                                }
                            }
                        );
                    }
                );
            }
        )
    );
    // dfmt on

    return sm;
}
