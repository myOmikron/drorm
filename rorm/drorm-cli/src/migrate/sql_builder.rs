use anyhow::Context;
use rorm_sql::alter_table::SQLAlterTableOperation;
use rorm_sql::DBImpl;

use crate::declaration::{Migration, Operation};

/**
Helper method to convert a migration to a transaction string

`db_impl`: [DBImpl]: The database implementation to use.
`migration`: [&Migration]: Reference to the migration that should be converted.
*/
pub fn migration_to_sql(db_impl: DBImpl, migration: &Migration) -> anyhow::Result<String> {
    let mut transaction = db_impl.start_transaction();

    for operation in &migration.operations {
        match &operation {
            Operation::CreateModel { name, fields } => {
                let mut create_table = db_impl.create_table(name.as_str());

                for field in fields {
                    create_table = create_table.add_column(db_impl.create_column(
                        name.as_str(),
                        field.name.as_str(),
                        field.db_type.clone(),
                        field.annotations.clone(),
                    ));
                }

                transaction =
                    transaction.add_statement(create_table.build().with_context(|| {
                        format!(
                            "Could not build create table operation for migration {}",
                            migration.id.as_str()
                        )
                    })?);
            }
            Operation::RenameModel { old, new } => {
                transaction = transaction.add_statement(
                    db_impl
                        .alter_table(
                            old.as_str(),
                            SQLAlterTableOperation::RenameTo {
                                name: new.to_string(),
                            },
                        )
                        .build()
                        .with_context(|| {
                            format!(
                                "Could not build rename table operation for migration {}",
                                migration.id.as_str()
                            )
                        })?,
                );
            }
            Operation::DeleteModel { name } => {
                transaction = transaction.add_statement(
                    db_impl.drop_table(name.as_str()).build().with_context(|| {
                        format!(
                            "Could not build drop table operation for migration {}",
                            migration.id.as_str()
                        )
                    })?,
                )
            }
            Operation::CreateField { model, field } => {
                transaction = transaction.add_statement(
                    db_impl
                        .alter_table(
                            model.as_str(),
                            SQLAlterTableOperation::AddColumn {
                                operation: db_impl.create_column(
                                    model.as_str(),
                                    field.name.as_str(),
                                    field.db_type.clone(),
                                    field.annotations.clone(),
                                ),
                            },
                        )
                        .build()
                        .with_context(|| {
                            format!(
                                "Could not build add column operation for migration {}",
                                migration.id.as_str()
                            )
                        })?,
                );
            }
            Operation::RenameField {
                table_name,
                old,
                new,
            } => {
                transaction = transaction.add_statement(
                    db_impl
                        .alter_table(
                            table_name.as_str(),
                            SQLAlterTableOperation::RenameColumnTo {
                                column_name: old.to_string(),
                                new_column_name: new.to_string(),
                            },
                        )
                        .build()
                        .with_context(|| {
                            format!(
                                "Could not build rename field operation for migration {}",
                                migration.id.as_str()
                            )
                        })?,
                )
            }
            Operation::DeleteField { model, name } => {
                transaction = transaction.add_statement(
                    db_impl
                        .alter_table(
                            model.as_str(),
                            SQLAlterTableOperation::DropColumn { name: name.clone() },
                        )
                        .build()
                        .with_context(|| {
                            format!(
                                "Could not build drop column operation for migration {}",
                                migration.id.as_str()
                            )
                        })?,
                );
            }
        }
    }

    Ok(transaction.finish().with_context(|| {
        format!(
            "Could not create transaction for migration {}",
            migration.id.as_str()
        )
    })?)
}
