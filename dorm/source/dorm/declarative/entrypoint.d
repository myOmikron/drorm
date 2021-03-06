module dorm.declarative.entrypoint;

mixin template RegisterModels()
{
	import dorm.declarative.conversion : processModelsToDeclarations;

	static immutable dormModelDeclarations = processModelsToDeclarations!(__traits(parent, {}));

	debug shared static this()
	{
		import std.algorithm : canFind;
		import core.runtime : Runtime;
		import core.stdc.stdlib;

		if (Runtime.args.canFind("--DORM-dump-models-json"))
		{
			import std.file : write;
			import mir.ser.json;

			string json = serializeJson(dormModelDeclarations);

			write(".models.json", `{"__comment":"generated by dorm:build-models build step, see documentation",` ~ json[1 .. $]);

			Runtime.terminate();
			exit(0);
		}
	}
}